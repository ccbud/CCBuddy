import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  buildDesktopRemoteProdEnv,
  resolvePnpmCommand,
  resolveProductionRemoteAssetCacheDir,
} from "../../../scripts/dev-desktop-remote-prod.mjs";

const rootPackageJsonPath = resolve(import.meta.dirname, "../../../package.json");
const rootPackageJson = JSON.parse(readFileSync(rootPackageJsonPath, "utf8")) as {
  scripts: Record<string, string | undefined>;
};

describe("dev desktop remote production-like script", () => {
  it("根 package.json 应提供生产态 remote 行为的 desktop dev 启动脚本", () => {
    expect(rootPackageJson.scripts["dev:desktop:remote-prod"]).toBe(
      "node scripts/dev-desktop-remote-prod.mjs",
    );
  });

  it("macOS 默认应复用正式版 CCbuddy remote cache", () => {
    expect(resolveProductionRemoteAssetCacheDir({}, "darwin", "/Users/alice")).toBe(
      "/Users/alice/Library/Application Support/CCbuddy/remote-assets-cache",
    );
  });

  it("Linux 默认应复用正式版 CCbuddy remote cache", () => {
    expect(resolveProductionRemoteAssetCacheDir({}, "linux", "/home/alice")).toBe(
      "/home/alice/.config/CCbuddy/remote-assets-cache",
    );
    expect(
      resolveProductionRemoteAssetCacheDir(
        { XDG_CONFIG_HOME: "/home/alice/.config-custom" },
        "linux",
        "/home/alice",
      ),
    ).toBe("/home/alice/.config-custom/CCbuddy/remote-assets-cache");
  });

  it("Windows 默认应复用正式版 CCbuddy remote cache", () => {
    expect(
      resolveProductionRemoteAssetCacheDir(
        { APPDATA: "C:\\Users\\Alice\\AppData\\Roaming" },
        "win32",
        "C:\\Users\\Alice",
      ),
    ).toBe("C:\\Users\\Alice\\AppData\\Roaming\\CCbuddy\\remote-assets-cache");
  });

  it("启动 env 应强制走 CDN，并允许显式 cache 覆盖", () => {
    const env = buildDesktopRemoteProdEnv(
      {
        CCBUDDY_ENV: "test",
        CCBUDDY_DEV_REMOTE_ASSET_USE_CDN: "0",
        CCBUDDY_REMOTE_ASSET_CACHE_DIR: "/tmp/custom-cache",
      },
      "darwin",
      "/Users/alice",
    );

    expect(env.CCBUDDY_ENV).toBe("production");
    expect(env.CCBUDDY_DEV_REMOTE_ASSET_USE_CDN).toBe("1");
    expect(env.CCBUDDY_REMOTE_ASSET_CACHE_DIR).toBe("/tmp/custom-cache");
  });

  it("Windows 下应使用 pnpm.cmd 启动", () => {
    expect(resolvePnpmCommand("win32")).toBe("pnpm.cmd");
    expect(resolvePnpmCommand("darwin")).toBe("pnpm");
  });
});
