import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, readdir, realpath, stat } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { HistoryDiagnostic, HistoryRoot, HistorySource } from "../contract.js";
import type { Candidate, SourceStamp } from "../domain/candidate.js";
export type { Candidate, SourceStamp } from "../domain/candidate.js";

const DEPTH: Record<HistorySource, number> = {
  claude: 4,
  codex: 7,
  qoder: 4,
  grok: 3,
  copilot: 2,
  antigravity: 1,
};

function eligible(source: HistorySource, parts: string[]): boolean {
  const name = parts.at(-1) ?? "";
  switch (source) {
    case "claude":
    case "qoder":
      return (
        (parts.length === 2 || (parts.length === 4 && parts[2] === "subagents")) &&
        extname(name) === ".jsonl"
      );
    case "codex":
      return parts.length <= 7 && /^rollout-.*\.jsonl$/.test(name);
    case "grok":
      return parts.length === 3 && (name === "chat_history.jsonl" || name === "updates.jsonl");
    case "copilot":
      return (
        (parts.length === 2 && name === "events.jsonl") ||
        (parts.length === 1 && extname(name) === ".jsonl")
      );
    case "antigravity":
      return parts.length === 1 && extname(name) === ".db";
  }
}

export function withinRoot(path: string, root: string): boolean {
  const rel = relative(root, path);
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

export function fingerprint(
  path: string,
  info: { size: bigint; mtimeNs: bigint; ino: bigint; dev: bigint },
): string {
  return createHash("sha256")
    .update(`${path}\0${info.size}\0${info.mtimeNs}\0${info.ino}\0${info.dev}`)
    .digest("hex");
}

export async function stamp(path: string, root: string): Promise<SourceStamp> {
  const canonical = await realpath(path);
  if (!withinRoot(canonical, root)) throw new Error("Path resolves outside its approved root");
  const link = await lstat(path);
  if (link.isSymbolicLink() || !link.isFile()) throw new Error("Source is not an ordinary file");
  const info = await stat(path, { bigint: true });
  if (!info.isFile()) throw new Error("Source is not an ordinary file");
  const created = Number(info.birthtimeMs || info.mtimeMs);
  const modified = Number(info.mtimeMs);
  return {
    path: canonical,
    size: info.size,
    mtimeNs: info.mtimeNs,
    inode: info.ino,
    device: info.dev,
    fingerprint: fingerprint(canonical, info),
    createdAt: new Date(created).toISOString(),
    modifiedAt: new Date(modified).toISOString(),
  };
}

/** SQLite may commit new conversation rows to its WAL without touching the database file. */
export async function stampSqlite(path: string, root: string): Promise<SourceStamp> {
  const primary = await stamp(path, root);
  const parts = [primary.fingerprint];
  let modifiedAt = primary.modifiedAt;
  for (const suffix of ["-wal", "-shm"]) {
    try {
      const sibling = await stamp(`${path}${suffix}`, root);
      parts.push(`${suffix}:${sibling.fingerprint}`);
      if (sibling.modifiedAt > modifiedAt) modifiedAt = sibling.modifiedAt;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      parts.push(`${suffix}:absent`);
    }
  }
  return {
    ...primary,
    fingerprint: createHash("sha256").update(parts.join("\0")).digest("hex"),
    modifiedAt,
  };
}

/** Opens the approved ordinary source, then compares the opened inode with the path stamp. */
export async function openVerified(candidate: Candidate) {
  const before = await stamp(candidate.path, candidate.root);
  const handle = await open(candidate.path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const actual = await handle.stat({ bigint: true });
    if (!actual.isFile() || actual.ino !== before.inode || actual.dev !== before.device) {
      throw new Error("Source changed while opening");
    }
    return { handle, before };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

function configuredRoot(environment: NodeJS.ProcessEnv, name: string, fallback: string): string {
  return environment[name]?.trim() || fallback;
}

export function defaultRoots(
  homeDirectory: string,
  environment: NodeJS.ProcessEnv = process.env,
): HistoryRoot[] {
  const codexHome = configuredRoot(environment, "CODEX_HOME", join(homeDirectory, ".codex"));
  const grokHome = configuredRoot(environment, "GROK_HOME", join(homeDirectory, ".grok"));
  const xdgHome = configuredRoot(environment, "XDG_CONFIG_HOME", join(homeDirectory, ".config"));
  return [
    { source: "claude", path: join(homeDirectory, ".claude", "projects") },
    { source: "claude", path: join(xdgHome, "claude", "projects") },
    { source: "codex", path: join(codexHome, "sessions") },
    { source: "codex", path: join(codexHome, "archived_sessions") },
    { source: "qoder", path: join(homeDirectory, ".qoder", "projects") },
    { source: "qoder", path: join(homeDirectory, ".qoderwork", "projects") },
    { source: "grok", path: join(grokHome, "sessions") },
    { source: "copilot", path: join(homeDirectory, ".copilot", "session-state") },
    {
      source: "antigravity",
      path: join(homeDirectory, ".gemini", "antigravity-cli", "conversations"),
    },
  ];
}

export async function discover(
  roots: readonly HistoryRoot[],
  explicitRoots: boolean,
  signal?: AbortSignal,
): Promise<{ candidates: Candidate[]; diagnostics: HistoryDiagnostic[] }> {
  const candidates: Candidate[] = [];
  const diagnostics: HistoryDiagnostic[] = [];
  const seen = new Set<string>();
  for (const root of roots) {
    if (signal?.aborted) break;
    const requested = resolve(root.path);
    let canonical: string;
    try {
      canonical = await realpath(requested);
      const info = await stat(canonical);
      if (!info.isDirectory()) throw new Error("Configured root is not a directory");
    } catch (error) {
      if (!explicitRoots && (error as NodeJS.ErrnoException).code === "ENOENT") continue;
      diagnostics.push({
        code: "unreadable_root",
        source: root.source,
        path: requested,
        message: String(error),
      });
      continue;
    }
    const walk = async (directory: string, parts: string[]): Promise<void> => {
      if (signal?.aborted || parts.length >= DEPTH[root.source]) return;
      let entries;
      try {
        entries = await readdir(directory, { withFileTypes: true });
      } catch (error) {
        diagnostics.push({
          code: "unreadable_root",
          source: root.source,
          path: directory,
          message: String(error),
        });
        return;
      }
      entries.sort((a, b) => a.name.localeCompare(b.name));
      for (const entry of entries) {
        if (signal?.aborted) return;
        const path = join(directory, entry.name);
        const childParts = [...parts, entry.name];
        if (entry.isSymbolicLink()) {
          diagnostics.push({
            code: "unsafe_path",
            source: root.source,
            path,
            message: "Symbolic links inside history roots are ignored",
          });
          continue;
        }
        if (entry.isDirectory()) {
          await walk(path, childParts);
        } else if (entry.isFile() && eligible(root.source, childParts)) {
          try {
            const sourceStamp =
              root.source === "antigravity"
                ? await stampSqlite(path, canonical)
                : await stamp(path, canonical);
            const key = `${root.source}\0${sourceStamp.path}`;
            if (seen.has(key)) continue;
            seen.add(key);
            candidates.push({
              source: root.source,
              path: sourceStamp.path,
              root: canonical,
              relativePath: childParts.join("/"),
              id: `${root.source}:${createHash("sha256")
                .update(root.source === "grok" ? dirname(sourceStamp.path) : sourceStamp.path)
                .digest("hex")
                .slice(0, 24)}`,
              stamp: sourceStamp,
            });
          } catch (error) {
            diagnostics.push({
              code: "unsafe_path",
              source: root.source,
              path,
              message: String(error),
            });
          }
        }
      }
    };
    await walk(canonical, []);
  }
  const grokWithChat = new Set(
    candidates
      .filter((item) => item.source === "grok" && item.path.endsWith(`${sep}chat_history.jsonl`))
      .map((item) => item.id),
  );
  const selected = candidates.filter(
    (item) =>
      item.source !== "grok" ||
      item.path.endsWith(`${sep}chat_history.jsonl`) ||
      !grokWithChat.has(item.id),
  );
  selected.sort((a, b) => a.source.localeCompare(b.source) || a.path.localeCompare(b.path));
  return { candidates: selected, diagnostics };
}
