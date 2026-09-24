import { join } from "node:path";
import { resolveCcBuddyDataRoot } from "@ccbuddy/contracts/workspace-state";

/** Keep extracted SEA assets with the rest of the CCbuddy CLI's application data. */
export function resolveSeaRuntimeCacheBaseDirectory(baseDir?: string): string {
  return join(resolveCcBuddyDataRoot(baseDir), "cli", "cache", "sea-assets");
}
