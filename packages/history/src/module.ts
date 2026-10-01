import { homedir } from "node:os";
import type { HistoryLibraryOptions, HistoryRoot } from "./contract.js";
import { HistoryLibraryCore } from "./app/history-library.js";
import { dedupeRoots, defaultRoots, detectClaudeProfileRoots } from "./adapters/discovery.js";
import { FileHistorySourceRepository } from "./adapters/history-source-repository.js";

async function resolveExtraRoots(options: HistoryLibraryOptions): Promise<HistoryRoot[]> {
  const extra = options.extraRoots ? await options.extraRoots() : [];
  return extra.map((root) => ({ ...root, origin: root.origin ?? "custom" }));
}

export class HistoryLibrary extends HistoryLibraryCore {
  constructor(options: HistoryLibraryOptions = {}) {
    const homeDirectory = options.homeDirectory ?? homedir();
    const environment = options.environment ?? process.env;
    super(
      options.roots ??
        (async () =>
          dedupeRoots([
            ...defaultRoots(
              homeDirectory,
              environment,
              options.ccbuddySessionDatabaseDirectory
                ? { ccbuddySessionDatabaseDirectory: options.ccbuddySessionDatabaseDirectory }
                : {},
            ),
            ...(await detectClaudeProfileRoots(homeDirectory)),
            ...(await resolveExtraRoots(options)),
          ])),
      options.roots !== undefined,
      new FileHistorySourceRepository(),
    );
  }
}

export { defaultRoots, detectClaudeProfileRoots } from "./adapters/discovery.js";
export * from "./contract.js";
