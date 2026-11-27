import { join } from "node:path";
import { resolveCcBuddyDataRoot } from "@ccbuddy/contracts/workspace-state";

export function getDefaultSessionDbPath(): string {
  return join(resolveCcBuddyDataRoot(), "cli", "db", "db.sqlite");
}
