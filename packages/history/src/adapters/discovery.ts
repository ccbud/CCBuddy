import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, readdir, realpath, stat } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type {
  HistoryDiagnostic,
  HistoryRoot,
  HistoryRootStatus,
  HistorySource,
} from "../contract.js";
import type { Candidate, SourceStamp } from "../domain/candidate.js";
export type { Candidate, SourceStamp } from "../domain/candidate.js";

export const CCBUDDY_SESSION_DATABASE_FILE = "db.sqlite";

const SQLITE_SOURCES: ReadonlySet<HistorySource> = new Set(["antigravity", "ccbuddy"]);

/** SQLite-backed producers need the composite database / WAL / shared-memory stamp. */
export function isSqliteSource(source: HistorySource): boolean {
  return SQLITE_SOURCES.has(source);
}

const DEPTH: Record<HistorySource, number> = {
  ccbuddy: 1,
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
    case "ccbuddy":
      return parts.length === 1 && name === CCBUDDY_SESSION_DATABASE_FILE;
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

/** First occurrence wins, so defaults keep their origin over later profile or custom duplicates. */
export function dedupeRoots(roots: readonly HistoryRoot[]): HistoryRoot[] {
  const seen = new Set<string>();
  const result: HistoryRoot[] = [];
  for (const root of roots) {
    const key = `${root.source}\0${resolve(root.path)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(root);
  }
  return result;
}

export interface DefaultRootOptions {
  /** Directory holding CCbuddy's own `db.sqlite`; defaults to `~/.ccbuddy/cli/db`. */
  ccbuddySessionDatabaseDirectory?: string;
}

export function defaultRoots(
  homeDirectory: string,
  environment: NodeJS.ProcessEnv = process.env,
  options: DefaultRootOptions = {},
): HistoryRoot[] {
  const codexHome = configuredRoot(environment, "CODEX_HOME", join(homeDirectory, ".codex"));
  const grokHome = configuredRoot(environment, "GROK_HOME", join(homeDirectory, ".grok"));
  const xdgHome = configuredRoot(environment, "XDG_CONFIG_HOME", join(homeDirectory, ".config"));
  const claudeConfigDirectory = environment["CLAUDE_CONFIG_DIR"]?.trim();
  const roots: HistoryRoot[] = [
    {
      source: "ccbuddy",
      path: options.ccbuddySessionDatabaseDirectory ?? join(homeDirectory, ".ccbuddy", "cli", "db"),
      origin: "default",
    },
    { source: "claude", path: join(homeDirectory, ".claude", "projects"), origin: "default" },
    { source: "claude", path: join(xdgHome, "claude", "projects"), origin: "default" },
    // Claude Code 的 CLAUDE_CONFIG_DIR 会把整套配置和 projects 搬到别处；只认 ~/.claude 会漏掉这台机器上真正在用的会话。
    ...(claudeConfigDirectory
      ? [
          {
            source: "claude" as const,
            path: join(claudeConfigDirectory, "projects"),
            origin: "environment" as const,
          },
        ]
      : []),
    { source: "codex", path: join(codexHome, "sessions"), origin: "default" },
    { source: "codex", path: join(codexHome, "archived_sessions"), origin: "default" },
    { source: "qoder", path: join(homeDirectory, ".qoder", "projects"), origin: "default" },
    { source: "qoder", path: join(homeDirectory, ".qoderwork", "projects"), origin: "default" },
    { source: "grok", path: join(grokHome, "sessions"), origin: "default" },
    {
      source: "copilot",
      path: join(homeDirectory, ".copilot", "session-state"),
      origin: "default",
    },
    {
      source: "antigravity",
      path: join(homeDirectory, ".gemini", "antigravity-cli", "conversations"),
      origin: "default",
    },
  ];
  return dedupeRoots(roots);
}

/**
 * Claude Code profiles created with CLAUDE_CONFIG_DIR usually sit beside `~/.claude`
 * (`~/.claude-work`, `~/.claude-config/<profile>`). A GUI launch does not inherit the shell's
 * CLAUDE_CONFIG_DIR, so any sibling that already has a `projects` directory is offered as a root.
 */
export async function detectClaudeProfileRoots(homeDirectory: string): Promise<HistoryRoot[]> {
  const found: HistoryRoot[] = [];
  const probe = async (directory: string): Promise<void> => {
    const projects = join(directory, "projects");
    try {
      if ((await stat(projects)).isDirectory()) {
        found.push({ source: "claude", path: projects, origin: "profile" });
      }
    } catch {
      /* not a Claude profile */
    }
  };
  const subdirectories = async (directory: string): Promise<string[]> => {
    try {
      const entries = await readdir(directory, { withFileTypes: true });
      return entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name);
    } catch {
      return [];
    }
  };
  for (const name of await subdirectories(homeDirectory)) {
    if (/^\.claude[-_.].+/.test(name)) await probe(join(homeDirectory, name));
  }
  const container = join(homeDirectory, ".claude-config");
  for (const name of await subdirectories(container)) await probe(join(container, name));
  return found;
}

/** Lets a producer whose file holds many sessions split one file into several catalog candidates. */
export type CandidateExpander = (candidate: Candidate) => Promise<Candidate[]>;

export async function discover(
  roots: readonly HistoryRoot[],
  explicitRoots: boolean,
  signal?: AbortSignal,
  expand?: CandidateExpander,
): Promise<{
  candidates: Candidate[];
  diagnostics: HistoryDiagnostic[];
  roots: HistoryRootStatus[];
}> {
  const candidates: Candidate[] = [];
  const diagnostics: HistoryDiagnostic[] = [];
  const statuses: HistoryRootStatus[] = [];
  const seen = new Set<string>();
  for (const root of roots) {
    if (signal?.aborted) break;
    const requested = resolve(root.path);
    const status: HistoryRootStatus = {
      source: root.source,
      path: requested,
      origin: root.origin ?? "custom",
      available: false,
    };
    statuses.push(status);
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
    status.available = true;
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
            const sourceStamp = isSqliteSource(root.source)
              ? await stampSqlite(path, canonical)
              : await stamp(path, canonical);
            const base: Candidate = {
              source: root.source,
              path: sourceStamp.path,
              root: canonical,
              relativePath: childParts.join("/"),
              id: `${root.source}:${createHash("sha256")
                .update(root.source === "grok" ? dirname(sourceStamp.path) : sourceStamp.path)
                .digest("hex")
                .slice(0, 24)}`,
              stamp: sourceStamp,
            };
            for (const item of expand ? await expand(base) : [base]) {
              const key = `${item.source}\0${item.path}\0${item.sessionId ?? ""}`;
              if (seen.has(key)) continue;
              seen.add(key);
              candidates.push(item);
            }
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
  selected.sort(
    (a, b) =>
      a.source.localeCompare(b.source) ||
      a.path.localeCompare(b.path) ||
      (a.sessionId ?? "").localeCompare(b.sessionId ?? ""),
  );
  return { candidates: selected, diagnostics, roots: statuses };
}
