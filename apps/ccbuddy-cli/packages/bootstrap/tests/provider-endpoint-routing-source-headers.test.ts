import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { arch as readOsArch, release as readOsRelease, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createProviderEndpointRoutingSourceHeaders } from "../src/provider-endpoint-routing-source-headers.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(
    tempDirs.splice(0).map((dir) => rm(dir, { force: true, recursive: true })),
  );
});

describe("createProviderEndpointRoutingSourceHeaders", () => {
  it("adds runtime attribution and reuses an existing deviceMid for the config GET", async () => {
    const dataBaseDir = await mkdtemp(
      join(tmpdir(), "ccbuddy-routing-source-headers-"),
    );
    tempDirs.push(dataBaseDir);
    const stateDir = join(dataBaseDir, ".ccbuddy", "v2");
    await mkdir(stateDir, { recursive: true });
    await writeFile(
      join(stateDir, "telemetry-state.json"),
      JSON.stringify({ deviceMid: "mid-routing-1" }),
      "utf8",
    );

    const headers = await createProviderEndpointRoutingSourceHeaders({
      appVersion: "1.2.3",
      env: {
        CCBUDDY_DATA_BASE_DIR: dataBaseDir,
        CCBUDDY_ENV: "test",
        CCBUDDY_TEST_BASE_URL: "https://routing-config.example.test",
      },
      sourceTitle: "electron",
    });

    expect(headers).toMatchObject({
      "HTTP-Referer": "https://routing-config.example.test",
      "User-Agent": "CCbuddy/1.2.3",
      "X-Client-Language": expect.any(String),
      "X-Client-Timezone": expect.any(String),
      "X-Device-Mid": "mid-routing-1",
      "X-Os-Category": osCategory(process.platform),
      "X-Os-Version": readOsRelease(),
      "X-Platform": `${process.platform}-${readOsArch()}`,
      "X-Release-Channel": "test",
      "X-Title": "Z Code@electron",
      "X-CCbuddy-App-Version": "1.2.3",
    });
    expect(headers).not.toHaveProperty("Authorization");
  });

  it("defaults to CLI attribution and does not create a missing device identity", async () => {
    const dataBaseDir = await mkdtemp(
      join(tmpdir(), "ccbuddy-routing-no-device-mid-"),
    );
    tempDirs.push(dataBaseDir);

    const headers = await createProviderEndpointRoutingSourceHeaders({
      env: {
        CCBUDDY_DATA_BASE_DIR: dataBaseDir,
        CCBUDDY_ENV: "production",
        CCBUDDY_APP_VERSION: "2.0.0",
      },
    });

    expect(headers).toMatchObject({
      "HTTP-Referer": "https://ccbuddy.z.ai",
      "User-Agent": "CCbuddy/2.0.0",
      "X-Release-Channel": "production",
      "X-Title": "Z Code@cli",
    });
    expect(headers).not.toHaveProperty("X-Device-Mid");
  });

  it("uses the Desktop-provided UI language for X-Client-Language", async () => {
    const dataBaseDir = await mkdtemp(join(tmpdir(), "ccbuddy-routing-client-language-"));
    tempDirs.push(dataBaseDir);
    const headers = await createProviderEndpointRoutingSourceHeaders({
      env: { CCBUDDY_CLIENT_LANGUAGE: "ru-RU", CCBUDDY_DATA_BASE_DIR: dataBaseDir },
    });
    expect(headers["X-Client-Language"]).toBe("ru-RU");
  });
});

function osCategory(platform: NodeJS.Platform): string {
  if (platform === "darwin") return "macos";
  if (platform === "win32") return "windows";
  return "linux";
}
