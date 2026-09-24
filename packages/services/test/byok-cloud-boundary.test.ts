import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createLocalOnlyApiClient } from "../src/providers/api/localOnlyApiClient.js";
import { createDisabledOAuthService } from "../src/oauth/disabledOAuthService.js";
import { createProviderRuntime } from "../src/model-provider/providerRuntime.js";
import { createClientScenesService } from "../src/client-scenes/clientScenesService.js";

test("workbench client scenes resolve locally without an account request", async () => {
  const previousFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("unexpected network request");
  };
  try {
    const scenes = createClientScenesService();
    assert.deepEqual(await scenes.list(), { code: 0, msg: "", data: [] });
    assert.deepEqual(await scenes.list(), { code: 0, msg: "", data: [] });
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("inherited cloud APIs and login stay closed without a network request", async () => {
  const previousFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("unexpected network request");
  };
  try {
    await assert.rejects(
      createLocalOnlyApiClient().request("https://ccbuddy.z.ai/api/v1/client/configs"),
      /unavailable/,
    );
    const oauth = createDisabledOAuthService();
    assert.deepEqual(await oauth.getProviders(), []);
    assert.deepEqual(await oauth.restoreCachedSessionState(), { status: "signed-out" });
    await assert.rejects(oauth.startOAuth("zai"), /user-configured model services/);
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("bundled provider release contains no account or retired gateway rules", async () => {
  const filePath = new URL("../../../config/provider/ccbuddy-builtin.json", import.meta.url);
  const release = JSON.parse(await readFile(filePath, "utf8")) as {
    config: {
      providerConfigRules: {
        providerRules: unknown[];
        templateRules: Array<{ config: { access: { type: string } } }>;
      };
      modelConfigRules: { modelApiRules: Array<{ baseUrlMatch?: string }> };
    };
  };
  assert.deepEqual(release.config.providerConfigRules.providerRules, []);
  assert.ok(
    release.config.providerConfigRules.templateRules.every(
      (rule) => !rule.config.access.type.includes("account"),
    ),
  );
  assert.ok(
    release.config.modelConfigRules.modelApiRules.every(
      (rule) => !rule.baseUrlMatch?.includes("ccbuddy"),
    ),
  );
});

test("a fresh CCbuddy profile has no selected model and does not fetch cloud config", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-byok-"));
  const previousFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("unexpected network request");
  };
  const runtime = createProviderRuntime({
    ccbuddyBuiltinFilePath: fileURLToPath(
      new URL("../../../config/provider/ccbuddy-builtin.json", import.meta.url),
    ),
    ccbuddyBuiltinActiveFilePath: join(root, ".ccbuddy", "v2", "provider", "builtin.json"),
    personalFilePath: join(root, ".ccbuddy", "v2", "provider_config.json"),
    personalPollingIntervalMs: false,
    watch: false,
  });
  try {
    await runtime.start();
    const view = await runtime.modelSelection.getView();
    assert.deepEqual(view.providers, []);
    assert.equal(view.preferredSelection, undefined);
    assert.equal(fetchCalls, 0);
  } finally {
    runtime.dispose();
    globalThis.fetch = previousFetch;
    await rm(root, { recursive: true, force: true });
  }
});
