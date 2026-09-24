import type { ApiClient } from "@ccbuddy/shared";

/** Account-era application APIs have no network destination in CCbuddy. */
export function createLocalOnlyApiClient(): ApiClient {
  return {
    async request(): Promise<Response> {
      throw new Error("CCbuddy account and cloud APIs are unavailable");
    },
  };
}
