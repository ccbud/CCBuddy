import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const APP_DATA_DIRECTORY = ".ccbuddy";
const WORKSPACES_DIRECTORY = "workspaces";
const WORKSPACE_KEY_HEX_LENGTH = 12;

export interface WorkspaceStatePathOptions {
  /** Base directory override, before the .ccbuddy component. */
  baseDir?: string;
  /** Explicit application-owned root, primarily for callers with a storage override. */
  dataRoot?: string;
  workspaceIdentity?: string;
}

export function resolveCcBuddyDataRoot(baseDir?: string): string {
  const configuredBase = baseDir ?? process.env.CCBUDDY_DATA_BASE_DIR?.trim() ?? homedir();
  return join(resolve(configuredBase || homedir()), APP_DATA_DIRECTORY);
}

/** Stable application-owned state directory for one logical workspace. */
export function resolveWorkspaceStateRoot(
  workspacePath: string,
  options: WorkspaceStatePathOptions = {},
): string {
  const identity = options.workspaceIdentity?.trim();
  // 与 services 的 workspaceHash 同源：identity 优先，路径按调用方原值参与哈希。
  const keySource = identity || workspacePath;
  const key = createHash("sha256").update(keySource).digest("hex").slice(0, WORKSPACE_KEY_HEX_LENGTH);
  return join(
    options.dataRoot ?? resolveCcBuddyDataRoot(options.baseDir),
    WORKSPACES_DIRECTORY,
    key,
  );
}
