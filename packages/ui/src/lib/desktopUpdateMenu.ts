import {
  CCBUDDY_PRODUCT_FLAVOR,
  type CCbuddyProductFlavor,
  type UpdateStatePayload,
} from "@ccbuddy/shared";

// 更新入口跟随产品身份而不是后端环境：Preview 身份（含生产后端的 Preview）禁用更新器。
export function shouldShowDesktopUpdateEntry(
  flavor: CCbuddyProductFlavor = CCBUDDY_PRODUCT_FLAVOR,
): boolean {
  return flavor === "production";
}

export function shouldDisplayDesktopUpdateEntry(
  state: UpdateStatePayload | null,
  flavor: CCbuddyProductFlavor = CCBUDDY_PRODUCT_FLAVOR,
): boolean {
  return (
    shouldShowDesktopUpdateEntry(flavor) &&
    state !== null &&
    (state.kind !== "idle" || state.enabled)
  );
}

export function getUpdateMenuLabelId(state: UpdateStatePayload | null) {
  switch (state?.kind) {
    case "checking":
      return "desktopMenu.help.checkingForUpdates";
    case "update-available":
      return "desktopMenu.help.updateAvailableVersion";
    case "download-progress":
      return "desktopMenu.help.downloadingUpdateProgress";
    case "update-downloaded":
      return "desktopMenu.help.restartToUpdate";
    case "idle":
    default:
      return "titleBar.menu.help.checkForUpdates";
  }
}

export function getUpdateMenuLabelValues(
  state: UpdateStatePayload | null,
): Record<string, string> | undefined {
  switch (state?.kind) {
    case "update-available":
    case "update-downloaded":
      return { version: state.version };
    case "download-progress":
      return { progress: state.progress };
    default:
      return undefined;
  }
}
