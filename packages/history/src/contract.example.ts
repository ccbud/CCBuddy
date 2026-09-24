import type { HistoryLibraryPort } from "./contract.js";

/** Example consumer: all actions pass through the read-only versioned port. */
export async function firstSessionTitle(history: HistoryLibraryPort): Promise<string | null> {
  await history.refresh();
  return history.list().sessions[0]?.title ?? null;
}
