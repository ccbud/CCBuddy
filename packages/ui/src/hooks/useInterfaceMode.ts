import { useCCbuddyStoreWithDefault } from "@/store/StoreProvider.js";

export function useIsOfficeMode(): boolean {
  return useCCbuddyStoreWithDefault((state) => state.interfaceMode === "office", false);
}
