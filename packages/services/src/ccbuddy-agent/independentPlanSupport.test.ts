import { expect, it, vi } from "vitest";
import { ensureGenUiContextSupport } from "./independentPlanSupport.js";
import type { CCbuddyProtocolClient } from "./ccbuddyProtocolClient.js";

it("shares capability checks per CLI connection and retries after rejection", async () => {
  const request = vi.fn().mockResolvedValueOnce({}).mockResolvedValue({ genUiContext: true });
  const client = { request } as unknown as CCbuddyProtocolClient;
  await expect(ensureGenUiContextSupport(client)).rejects.toThrow("proto.genUiContextUnsupported");
  await Promise.all([ensureGenUiContextSupport(client), ensureGenUiContextSupport(client)]);
  await ensureGenUiContextSupport(client);
  expect(request).toHaveBeenCalledTimes(2);
});

it("rejects transport failures rather than sending context-free input", async () => {
  const failure = new Error("offline");
  const client = {
    request: vi.fn().mockRejectedValue(failure),
  } as unknown as CCbuddyProtocolClient;
  await expect(ensureGenUiContextSupport(client)).rejects.toMatchObject({
    message: "proto.genUiContextUnsupported",
    cause: failure,
  });
});
