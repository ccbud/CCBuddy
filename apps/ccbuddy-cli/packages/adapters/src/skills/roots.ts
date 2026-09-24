import { stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import type { SkillRoot, SkillSource } from "@ccbuddy/contracts";
import {
  resolveCcBuddyDataRoot,
  resolveWorkspaceStateRoot,
} from "@ccbuddy/contracts/workspace-state";

const GIT_MARKER = ".git";
const HOME_PREFIX = "~/";
const PRIORITY_STEP = 10;
const SKILLS_DIR = "skills";
const AGENTS_DIR = ".agents";

export interface SkillRootResolutionOptions {
  homeDirectory?: string;
  workspaceIdentity?: string;
  extraRoots?: string[];
  extraResolvedRoots?: SkillRoot[];
  includeCCbuddySkills?: boolean;
}

export async function resolveDefaultSkillRoots(
  workingDirectory: string,
  options: SkillRootResolutionOptions = {},
): Promise<SkillRoot[]> {
  const resolvedWorkingDirectory = resolve(workingDirectory);
  const roots: SkillRoot[] = [];
  const includeCCbuddy = options.includeCCbuddySkills ?? true;
  const home = options.homeDirectory ?? homedir();
  let priority = 0;
  const nextPriority = () => {
    priority += PRIORITY_STEP;
    return priority;
  };

  for (const extraRoot of options.extraRoots ?? []) {
    roots.push(
      root(
        resolveConfiguredRoot(extraRoot, resolvedWorkingDirectory),
        "project",
        "ccbuddy",
        nextPriority(),
      ),
    );
  }

  if (includeCCbuddy) {
    roots.push(
      root(
        join(resolveCcBuddyDataRoot(options.homeDirectory), SKILLS_DIR),
        "user",
        "ccbuddy",
        nextPriority(),
      ),
      root(join(home, AGENTS_DIR, SKILLS_DIR), "user", "agents", nextPriority()),
    );
  }

  const projectDirectories = await resolveProjectSkillDirectories(resolvedWorkingDirectory);
  if (includeCCbuddy) {
    roots.push(
      root(
        join(
          resolveWorkspaceStateRoot(resolvedWorkingDirectory, {
            baseDir: options.homeDirectory,
            workspaceIdentity: options.workspaceIdentity,
          }),
          SKILLS_DIR,
        ),
        "project",
        "ccbuddy",
        nextPriority(),
      ),
    );
  }
  for (const directory of projectDirectories) {
    if (includeCCbuddy) {
      roots.push(...skillRootsForBase(directory, "project", nextPriority));
    }
  }

  roots.push(...(options.extraResolvedRoots ?? []));

  return roots;
}

async function resolveProjectSkillDirectories(workingDirectory: string): Promise<string[]> {
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

function skillRootsForBase(
  baseDirectory: string,
  scope: SkillRoot["scope"],
  nextPriority: () => number,
): SkillRoot[] {
  // 项目内只发现显式的兼容技能目录；CCbuddy 自己的状态位于应用数据根。
  return [root(join(baseDirectory, AGENTS_DIR, SKILLS_DIR), scope, "agents", nextPriority())];
}

function root(
  path: string,
  scope: SkillRoot["scope"],
  source: SkillSource,
  priority: number,
): SkillRoot {
  return {
    path: resolve(path),
    scope,
    source,
    priority,
  };
}

function resolveConfiguredRoot(path: string, workingDirectory: string): string {
  const expanded = path.startsWith(HOME_PREFIX)
    ? join(homedir(), path.slice(HOME_PREFIX.length))
    : path;
  return isAbsolute(expanded) ? expanded : resolve(workingDirectory, expanded);
}
