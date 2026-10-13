import type { IPlatformService } from "@ccbuddy/shared";

function isMacOsDesktopUserAgent(): boolean {
  return (
    typeof navigator !== "undefined" &&
    /Macintosh|Mac OS X/.test(navigator.userAgent) &&
    !/iPhone|iPad|iPod/.test(navigator.userAgent)
  );
}

function isWindowsDesktopUserAgent(): boolean {
  return typeof navigator !== "undefined" && /Windows/i.test(navigator.userAgent);
}

/**
 * CUA 权限 UI 的真实平台能力门。
 *
 * 仅看 UA 会把 macOS Safari/Web 误判成 desktop，打开一个无法执行任何本机 IPC 的权限弹窗。
 * desktop preload 只在具备该能力时注入 onboarding 方法，因此 UA + capability 必须同时满足。
 */
export function supportsLocalMacCuaPermissionOnboarding(
  platform: Pick<IPlatformService, "openCuaPermissionOnboarding"> | null | undefined,
): boolean {
  return isMacOsDesktopUserAgent() && typeof platform?.openCuaPermissionOnboarding === "function";
}

/**
 * Windows 本地桌面的 CUA 能力门（与上面的 mac 门对称）。
 *
 * Windows 无 TCC，不读 Helper 权限，因此不能用 openCuaPermissionOnboarding 当 capability 判据；
 * 改用 executeDesktopCommand——它只在 desktop preload 注入，能把 Windows 上的普通浏览器排除掉。
 */
export function supportsLocalWindowsCuaEntry(
  platform: Pick<IPlatformService, "executeDesktopCommand"> | null | undefined,
): boolean {
  return isWindowsDesktopUserAgent() && typeof platform?.executeDesktopCommand === "function";
}
