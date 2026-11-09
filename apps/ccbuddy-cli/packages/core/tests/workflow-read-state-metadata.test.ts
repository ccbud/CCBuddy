import { expect, it } from "vitest";
import { parseReadFileStateMetadata } from "../src/tool/read-file-state-metadata.js";

it("restores successful FillWorkflowHole snapshots through the same parser as writes", () => {
  const readFileState = {
    schemaVersion: 1,
    tool: "FillWorkflowHole",
    path: "/workflow/fill.ts",
    content: "return 42",
    isPartialView: false,
    readAtMs: 1,
    revisionId: "revision",
    mtimeMs: 1,
    sizeBytes: 9,
    snapshotIndex: 2,
  };
  expect(parseReadFileStateMetadata({ readFileState })).toEqual(readFileState);
  expect(
    parseReadFileStateMetadata({ readFileState: { ...readFileState, tool: "Unknown" } }),
  ).toBeUndefined();
});
