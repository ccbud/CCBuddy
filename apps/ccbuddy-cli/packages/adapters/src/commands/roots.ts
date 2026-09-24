import { stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import type { CustomCommandRoot, CustomCommandSource } from "@ccbuddy/contracts";
import {
  resolveCcBuddyDataRoot,
  resolveWorkspaceStateRoot,
} from "@ccbuddy/contracts/workspace-state";

const COMMANDS_DIR = "commands";
const GIT_MARKER = ".git";
const HOME_PREFIX = "~/";
const PRIORITY_STEP = 10;
const AGENTS_DIR = ".agents";

export interface CustomCommandRootResolutionOptions {
  extraRoots?: string[];
  extraResolvedRoots?: CustomCommandRoot[];
  homeDirectory?: string;
  workspaceIdentity?: string;
  includeCCbuddyCommands?: boolean;
}

export async function resolveDefaultCustomCommandRoots(
  workingDirectory: string,
  options: CustomCommandRootResolutionOptions = {},
): Promise<CustomCommandRoot[]> {
  const resolvedWorkingDirectory = resolve(workingDirectory);
  const roots: CustomCommandRoot[] = [];
  const includeCCbuddy = options.includeCCbuddyCommands ?? true;
  const home = options.homeDirectory ?? homedir();
  let priority = 0;
  const nextPriority = () => {
    priority += PRIORITY_STEP;
    return priority;
  };

  for (const extraRoot of options.extraRoots ?? []) {
    roots.push(
      root(
        resolveConfiguredRoot(extraRoot, resolvedWorkingDirectory, home),
        "project",
        "ccbuddy",
        nextPriority(),
      ),
    );
  }

  if (includeCCbuddy) {
    roots.push(
      root(
        join(resolveCcBuddyDataRoot(options.homeDirectory), COMMANDS_DIR),
        "user",
        "ccbuddy",
        nextPriority(),
      ),
      root(join(home, AGENTS_DIR, COMMANDS_DIR), "user", "agents", nextPriority()),
    );
  }

  const projectDirectories = await resolveProjectDirectories(resolvedWorkingDirectory);
  if (includeCCbuddy) {
    roots.push(
      root(
        join(
          resolveWorkspaceStateRoot(resolvedWorkingDirectory, {
            baseDir: options.homeDirectory,
            workspaceIdentity: options.workspaceIdentity,
          }),
          COMMANDS_DIR,
        ),
        "project",
        "ccbuddy",
        nextPriority(),
      ),
    );
  }
  for (const directory of projectDirectories) {
    if (includeCCbuddy) {
      roots.push(...commandRootsForBase(directory, "project", nextPriority));
    }
  }

  roots.push(...(options.extraResolvedRoots ?? []));

  return roots;
}

async function resolveProjectDirectories(workingDirectory: string): Promise<string[]> {
  const worktreeRoot = await findWorktreeRoot(workingDirectory);
  if (!worktreeRoot) return [workingDirectory];

  const directories: string[] = [];
  let current = workingDirectory;
  while (true) {
    directories.push(current);
    if (current === worktreeRoot || current === dirname(current)) break;
    current = dirname(current);
  }
  return directories;
}

async function findWorktreeRoot(workingDirectory: string): Promise<string | null> {
  let current = workingDirectory;
  while (true) {
    if (await pathExists(join(current, GIT_MARKER))) return current;
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

function commandRootsForBase(
  baseDirectory: string,
  scope: CustomCommandRoot["scope"],
  nextPriority: () => number,
): CustomCommandRoot[] {
  // 项目内只发现显式的兼容命令目录；CCbuddy 自己的状态位于应用数据根。
  return [root(join(baseDirectory, AGENTS_DIR, COMMANDS_DIR), scope, "agents", nextPriority())];
}

function root(
  path: string,
  scope: CustomCommandRoot["scope"],
  source: CustomCommandSource,
  priority: number,
): CustomCommandRoot {
  return {
    path: resolve(path),
    scope,
    source,
    priority,
  };
}

function resolveConfiguredRoot(path: string, workingDirectory: string, home: string): string {
  const expanded = path.startsWith(HOME_PREFIX) ? join(home, path.slice(HOME_PREFIX.length)) : path;
  return isAbsolute(expanded) ? expanded : resolve(workingDirectory, expanded);
}
