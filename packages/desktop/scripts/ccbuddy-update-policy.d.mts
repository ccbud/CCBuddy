export declare function normalizeCCbuddyUpdateManifestUrl(value?: string | null): string | null;
export declare function resolveCCbuddyDesktopUpdatePolicy(options: {
  flavor: "production" | "preview";
  manifestUrl?: string;
}): {
  autoUpdateEnabled: boolean;
  updateFeedSource: { url: string } | undefined;
};
