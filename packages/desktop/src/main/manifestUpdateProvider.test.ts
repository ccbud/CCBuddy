import assert from "node:assert/strict";
import test from "node:test";
import { ManifestUpdateProvider } from "./manifestUpdateProvider.js";

test("an electron-builder YAML manifest resolves its ZIP beside the manifest", async () => {
  const manifestUrl = "https://updates.example.test/releases/2.0.10/latest-mac.yml";
  const zipName = "CCbuddy-2.0.10-mac-arm64.zip";
  const yaml = `version: 2.0.10
files:
  - url: ${zipName}
    sha512: Zml4dHVyZS1jaGVja3N1bQ==
    size: 1234
path: ${zipName}
sha512: Zml4dHVyZS1jaGVja3N1bQ==
releaseDate: '2026-09-24T00:00:00.000Z'
`;
  let requestedPath: string | undefined;
  const provider = new ManifestUpdateProvider(
    { manifestUrl, releaseChannel: "stable", releasePlatform: "darwin-aarch64" },
    {} as ConstructorParameters<typeof ManifestUpdateProvider>[1],
    {
      executor: {
        request: async (options: { path?: string }) => {
          requestedPath = options.path;
          return yaml;
        },
      },
      isUseMultipleRangeRequest: false,
      platform: "darwin",
    } as unknown as ConstructorParameters<typeof ManifestUpdateProvider>[2],
  );

  const info = await provider.getLatestVersion();
  assert.equal(requestedPath, "/releases/2.0.10/latest-mac.yml?platform=darwin-aarch64&channel=1");
  assert.equal(info.version, "2.0.10");
  assert.equal(
    provider.resolveFiles(info)[0]?.url.href,
    "https://updates.example.test/releases/2.0.10/CCbuddy-2.0.10-mac-arm64.zip",
  );

  const alternateFiles = provider.resolveFiles({
    ...info,
    files: [
      { url: "/shared/root.zip", sha512: "Zml4dHVyZQ==" },
      { url: "https://cdn.example.test/releases/absolute.zip", sha512: "Zml4dHVyZQ==" },
    ],
  });
  assert.deepEqual(
    alternateFiles.map((file) => file.url.href),
    [
      "https://updates.example.test/shared/root.zip",
      "https://cdn.example.test/releases/absolute.zip",
    ],
  );
});
