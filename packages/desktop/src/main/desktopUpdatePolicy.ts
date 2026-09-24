import { CCBUDDY_PRODUCT_FLAVOR } from "@ccbuddy/shared";
import { resolveCCbuddyDesktopUpdatePolicy } from "../../scripts/ccbuddy-update-policy.mjs";

declare const __CCBUDDY_UPDATE_MANIFEST_URL__: string;

/** One immutable policy shared by startup, menu, tray, and command admission. */
export const desktopUpdatePolicy = resolveCCbuddyDesktopUpdatePolicy({
  flavor: CCBUDDY_PRODUCT_FLAVOR,
  manifestUrl:
    typeof __CCBUDDY_UPDATE_MANIFEST_URL__ !== "undefined"
      ? __CCBUDDY_UPDATE_MANIFEST_URL__
      : undefined,
});
