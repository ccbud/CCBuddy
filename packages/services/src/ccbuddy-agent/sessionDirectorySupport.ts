import { ccbuddyProtocolMethods, ccbuddyRuntimeCapabilitiesSchema } from "@ccbuddy/shared";
import type { CCbuddyProtocolClient } from "./ccbuddyProtocolClient.js";

const checks = new WeakMap<object, Promise<boolean>>();

export function negotiateSessionDirectorySource(
  client: Pick<CCbuddyProtocolClient, "request">,
): Promise<boolean> {
  const cached = checks.get(client);
  if (cached) return cached;
  const check = client
    .request(
      ccbuddyProtocolMethods.runtimeCapabilities,
      { hostCapabilities: { sessionDirectorySource: true } },
      ccbuddyRuntimeCapabilitiesSchema,
    )
    .then((result) => result.sessionDirectorySource === true)
    .catch((error: unknown) => {
      checks.delete(client);
      if (typeof error === "object" && error !== null && "code" in error && error.code === -32601)
        return false;
      throw error;
    });
  checks.set(client, check);
  return check;
}
