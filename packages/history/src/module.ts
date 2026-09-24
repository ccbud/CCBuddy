import { homedir } from "node:os";
import type { HistoryLibraryOptions } from "./contract.js";
import { HistoryLibraryCore } from "./app/history-library.js";
import { defaultRoots } from "./adapters/discovery.js";
import { FileHistorySourceRepository } from "./adapters/history-source-repository.js";

export class HistoryLibrary extends HistoryLibraryCore {
  constructor(options: HistoryLibraryOptions = {}) {
    super(
      options.roots ?? defaultRoots(options.homeDirectory ?? homedir()),
      options.roots !== undefined,
      new FileHistorySourceRepository(),
    );
  }
}

export * from "./contract.js";
