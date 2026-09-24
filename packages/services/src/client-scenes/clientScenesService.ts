import type { ClientScenesResponse, IClientScenesService } from "./clientScenes.js";

/** The retired cloud scene catalog has no CCbuddy source. Keep manual flows available. */
export function createClientScenesService(): IClientScenesService {
  return {
    async list(): Promise<ClientScenesResponse> {
      return { code: 0, msg: "", data: [] };
    },
  };
}
