import { expect, it, vi } from "vitest";
import { negotiateSessionDirectorySource } from "./sessionDirectorySupport.js";

it("declares the Host capability before publishing directory sources, sharing one flight", async () => {
  const request = vi.fn().mockResolvedValue({ sessionDirectorySource: true });
  const client = { request };
  await expect(
    Promise.all([negotiateSessionDirectorySource(client), negotiateSessionDirectorySource(client)]),
  ).resolves.toEqual([true, true]);
  expect(request).toHaveBeenCalledOnce();
  expect(request.mock.calls[0]?.[1]).toEqual({
    hostCapabilities: { sessionDirectorySource: true },
  });
});

it("does not mistake transport failure for old CLI support", async () => {
  const request = vi
    .fn()
    .mockRejectedValueOnce(new Error("disconnected"))
    .mockResolvedValueOnce({ sessionDirectorySource: true });
  const client = { request };
  await expect(negotiateSessionDirectorySource(client)).rejects.toThrow("disconnected");
  await expect(negotiateSessionDirectorySource(client)).resolves.toBe(true);
  await expect(
    negotiateSessionDirectorySource({ request: vi.fn().mockRejectedValue({ code: -32601 }) }),
  ).resolves.toBe(false);
});
