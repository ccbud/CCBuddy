import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import {
  ensureDefaultPluginMarketplaces,
  ensureMarketplaceManifestAvailable,
  updateMarketplace,
} from "../src/plugins/marketplace.ts";
import { writeBundledOfficialMarketplacePartitionSync } from "../src/plugins/official-marketplace.ts";

const OFFICIAL_ID = "ccbuddy-plugins-official";

test("official plugin inventory stays local even when an older record points to CCbuddy CDN", async () => {
  const storageRoot = await mkdtemp(join(tmpdir(), "ccbuddy-plugin-marketplace-"));
  try {
    await writeFile(
      join(storageRoot, "known_marketplaces.json"),
      JSON.stringify({
        version: 1,
        marketplaces: [
          {
            id: OFFICIAL_ID,
            name: OFFICIAL_ID,
            source: { source: "url", url: "https://cdn-ccbuddy.z.ai/obsolete-marketplace.json" },
            addedAt: "2025-01-01T00:00:00.000Z",
            pluginCount: 0,
          },
        ],
      }),
    );

    const [record] = ensureDefaultPluginMarketplaces(storageRoot);
    const localManifest = join(storageRoot, "marketplaces", OFFICIAL_ID, "marketplace.json");
    assert.deepEqual(record?.source, { source: "file", path: localManifest });
    assert.equal(record?.name, "CCbuddy built-in plugins");
    assert.equal(
      await ensureMarketplaceManifestAvailable({ marketplace: OFFICIAL_ID, storageRoot }),
      null,
    );

    const refreshed = await updateMarketplace({ marketplace: OFFICIAL_ID, storageRoot });
    assert.equal(refreshed.length, 1);
    assert.deepEqual(refreshed[0]?.source, { source: "file", path: localManifest });
    assert.equal(
      JSON.parse(await readFile(join(storageRoot, "known_marketplaces.json"), "utf8"))
        .marketplaces[0].source.source,
      "file",
    );

    await mkdir(dirname(localManifest), { recursive: true });
    await writeFile(localManifest, JSON.stringify({ name: OFFICIAL_ID, plugins: [] }));
    assert.equal(
      (await ensureMarketplaceManifestAvailable({ marketplace: OFFICIAL_ID, storageRoot }))?.id,
      OFFICIAL_ID,
    );
  } finally {
    await rm(storageRoot, { recursive: true, force: true });
  }
});

test("bundled marketplace does not include an older CDN partition", async () => {
  const storageRoot = await mkdtemp(join(tmpdir(), "ccbuddy-bundled-marketplace-"));
  try {
    const marketplaceDir = join(storageRoot, "marketplaces", OFFICIAL_ID);
    await mkdir(marketplaceDir, { recursive: true });
    await writeFile(
      join(marketplaceDir, "cdn-marketplace.json"),
      JSON.stringify({ name: OFFICIAL_ID, plugins: [{ name: "remote-only" }] }),
    );
    writeBundledOfficialMarketplacePartitionSync({
      storageRoot,
      manifest: { name: OFFICIAL_ID, plugins: [{ name: "bundled-only" }] },
    });
    const merged = JSON.parse(await readFile(join(marketplaceDir, "marketplace.json"), "utf8"));
    assert.deepEqual(merged.plugins, [{ name: "bundled-only" }]);
  } finally {
    await rm(storageRoot, { recursive: true, force: true });
  }
});
