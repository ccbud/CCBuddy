import { expect, it } from "vitest";
import { v4SessionDataParamsSchema, v4SessionDataPurgeResultSchema } from "./contract.js";

it("rejects unknown deletion fields and invalid result accounting", () => {
  expect(v4SessionDataParamsSchema.parse({ sessionIds: [], directories: [] })).toEqual({
    sessionIds: [],
    directories: [],
  });
  expect(
    v4SessionDataParamsSchema.safeParse({ sessionIds: ["session"], directories: [], force: true })
      .success,
  ).toBe(false);
  expect(
    v4SessionDataPurgeResultSchema.safeParse({
      deleted: [{ sessionId: "session", bytes: -1 }],
      kept: [],
      failed: [],
      memory: [],
    }).success,
  ).toBe(false);
});
