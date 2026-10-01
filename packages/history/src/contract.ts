/** The renderer-facing, versioned read contract. No filesystem operation is exposed. */
export * from "./domain/contract-types.js";
export {
  parseHistoryRefreshEvent,
  parseHistorySessionDetail,
  parseHistorySnapshot,
} from "./domain/contract-validation.js";
