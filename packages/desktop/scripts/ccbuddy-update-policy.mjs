/**
 * Resolve the immutable update source embedded in a CCbuddy build. An unset
 * source disables updates; never fall back to CCbuddy's default release server.
 */
export function normalizeCCbuddyUpdateManifestUrl(value) {
  const trimmed = value?.trim();
  if (!trimmed) return null;

  let url;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error("CCBUDDY_UPDATE_MANIFEST_URL must be an absolute HTTPS URL");
  }
  if (url.protocol !== "https:" || url.username || url.password || url.hash) {
    throw new Error("CCBUDDY_UPDATE_MANIFEST_URL must be an HTTPS URL without credentials or hash");
  }
  return url.toString();
}

/**
 * @param {{ flavor: "production" | "preview", manifestUrl?: string }} options
 */
export function resolveCCbuddyDesktopUpdatePolicy(options) {
  const manifestUrl = normalizeCCbuddyUpdateManifestUrl(options.manifestUrl);
  const autoUpdateEnabled = options.flavor === "production" && manifestUrl !== null;
  return {
    autoUpdateEnabled,
    updateFeedSource: autoUpdateEnabled ? { url: manifestUrl } : undefined,
  };
}
