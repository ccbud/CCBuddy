import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { resolveCcBuddyDataRoot } from "@ccbuddy/contracts/workspace-state";
import { maybeThrowStorageFsFault } from "../fs-fault-injection.js";

export function getDefaultSessionDbPath(): string {
  return join(resolveCcBuddyDataRoot(), "cli", "db", "db.sqlite");
}

export function ensureParentDir(filePath: string): void {
  const parent = dirname(filePath);
  if (!existsSync(parent)) {
    maybeThrowStorageFsFault({ operation: "mkdir", path: parent });
    mkdirSync(parent, { recursive: true });
  }
}
