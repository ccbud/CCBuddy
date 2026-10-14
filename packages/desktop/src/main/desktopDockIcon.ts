import { app, nativeImage } from "electron";
import { dirname, join } from "node:path";

export function applyAppIcon(iconPath: string): void {
  if (process.platform !== "darwin" || app.dock == null || app.isPackaged) {
    return;
  }

  // 修复原因：启动时用铺满画布的窗口 PNG 覆盖 Dock，会绕过系统对 bundle 图标的呈现，
  // 导致启动后图标变大。正式包保留系统图标；开发态使用四边留白的专用 macOS 资源。
  const dockIcon = nativeImage.createFromPath(join(dirname(iconPath), "icon_macos.png"));
  if (!dockIcon.isEmpty()) {
    app.dock.setIcon(dockIcon);
  }
}
