export const projectStorageModule = {
  id: "project-storage",
  requires: ["shared", "sqlite-migrations"],
  provides: ["project-storage"],
  publicEntrypoints: ["index.ts", "contract.ts"],
} as const;
