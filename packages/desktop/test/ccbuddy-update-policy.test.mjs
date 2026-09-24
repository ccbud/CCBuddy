import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  normalizeCCbuddyUpdateManifestUrl,
  resolveCCbuddyDesktopUpdatePolicy,
} from "../scripts/ccbuddy-update-policy.mjs";

test("production CCbuddy without its own feed cannot adopt CCbuddy's release feed", () => {
  // Regression: CCbuddy v0.1.0 used to quit before its first window when CCbuddy
  // advertised minimalVersion 3.5.3. No CCbuddy feed is configured by default.
  const policy = resolveCCbuddyDesktopUpdatePolicy({ flavor: "production" });
  assert.deepEqual(policy, {
    autoUpdateEnabled: false,
    updateFeedSource: undefined,
  });
});

test("the production startup entrypoint does not call the inherited CCbuddy gate", async () => {
  const entrypointPath = fileURLToPath(new URL("../src/main/index.ts", import.meta.url));
  const entrypoint = await readFile(entrypointPath, "utf8");
  assert.equal(/maybeBlockStartupForForceUpdate\s*\(/.test(entrypoint), false);
  assert.equal(/from\s+["']\.\/forceUpdateGuard\.js["']/.test(entrypoint), false);
  assert.equal(/resolveUpdateFeedSourceFromStartupConfig\s*\(/.test(entrypoint), false);
});

test("disabled updater rejects the settings-refresh and legacy force-update bypasses", async () => {
  const updaterPath = fileURLToPath(new URL("../src/main/autoUpdater.ts", import.meta.url));
  const updater = await readFile(updaterPath, "utf8");
  for (const [startName, endName] of [
    [
      "export function refreshAutoUpdaterReleaseChannel(",
      "export function syncAutoUpdaterStateToWindow(",
    ],
    ["export function requestForceAutoUpdate(", "export function checkForUpdateMenuClick("],
  ]) {
    const start = updater.indexOf(startName);
    const end = updater.indexOf(endName, start + startName.length);
    assert.ok(start >= 0 && end > start, `missing updater entrypoint: ${startName}`);
    const body = updater.slice(start, end);
    const guard = body.indexOf("if (autoUpdaterDisabledForProductFlavor)");
    const request = body.indexOf(".checkForUpdates()");
    assert.ok(guard >= 0 && request > guard, `disabled guard must precede ${startName} request`);
  }
});

test("disabled CCbuddy ignores inherited CCbuddy ready updates without changing shared settings", async () => {
  const policy = resolveCCbuddyDesktopUpdatePolicy({ flavor: "production" });
  assert.equal(policy.autoUpdateEnabled, false);

  const entrypoint = await readFile(
    fileURLToPath(new URL("../src/main/index.ts", import.meta.url)),
    "utf8",
  );
  assert.match(
    entrypoint,
    /if\s*\(desktopUpdatePolicy\.autoUpdateEnabled\)\s*\{\s*await hydratePendingPostUpdateReleaseNotes\(mainSettingService\)/,
    "a disabled CCbuddy must not hydrate the shared CCbuddy pending release",
  );

  const updater = await readFile(
    fileURLToPath(new URL("../src/main/autoUpdater.ts", import.meta.url)),
    "utf8",
  );
  const disabledBranch = updater
    .split("if (options.enabled === false) {")[1]
    ?.split("autoUpdaterDisabledForProductFlavor = false;")[0];
  assert.ok(disabledBranch, "missing disabled updater branch");
  assert.match(disabledBranch, /clearReadyUpdateState\(\)/);
  assert.match(disabledBranch, /pendingPostUpdateReleaseNotes = null/);
  assert.doesNotMatch(
    disabledBranch,
    /settingService\.update|clearPendingPostUpdateReleaseNotes\(/,
  );

  for (const [functionName, channel] of [
    ["syncReadyUpdateToWindow", "UpdateReady"],
    ["syncPostUpdateReleaseNotesToWindow", "PostUpdateReleaseNotes"],
  ]) {
    const body = updater.split(`export function ${functionName}(`)[1]?.split("\nexport ")[0];
    assert.ok(body, `missing ${functionName}`);
    assert.match(
      body,
      /if\s*\(autoUpdaterDisabledForProductFlavor\s*\|\|/,
      `${functionName} must reject disabled updates before sending ${channel}`,
    );
    assert.ok(body.indexOf("autoUpdaterDisabledForProductFlavor") < body.indexOf(channel));
  }
});

test("CCbuddy and CCbuddy pending releases survive settings validation independently", async () => {
  const { appSettingsSchema, appSettingsPatchSchema } =
    await import("../../shared/src/validationAppSettings.ts");
  const ccbuddyPending = { version: "0.2.0", title: "CCbuddy", markdown: "CCbuddy release" };
  const settings = appSettingsSchema.parse({
    pendingPostUpdateReleaseNotes: ccbuddyPending,
    ccbuddyPendingPostUpdateReleaseNotes: ccbuddyPending,
  });
  assert.deepEqual(settings.pendingPostUpdateReleaseNotes, ccbuddyPending);
  assert.deepEqual(settings.ccbuddyPendingPostUpdateReleaseNotes, ccbuddyPending);
  assert.deepEqual(
    appSettingsPatchSchema.parse({ ccbuddyPendingPostUpdateReleaseNotes: ccbuddyPending }),
    { ccbuddyPendingPostUpdateReleaseNotes: ccbuddyPending },
  );
});

test("the CCbuddy updater never recovers or overwrites CCbuddy's pending release", async () => {
  const updater = await readFile(
    fileURLToPath(new URL("../src/main/autoUpdater.ts", import.meta.url)),
    "utf8",
  );
  assert.match(updater, /settings\.ccbuddyPendingPostUpdateReleaseNotes/);
  assert.match(
    updater,
    /settingService\.update\(\{ ccbuddyPendingPostUpdateReleaseNotes: payload \}\)/,
  );
  assert.doesNotMatch(updater, /settings\.pendingPostUpdateReleaseNotes\b/);
  assert.doesNotMatch(updater, /settingService\.update\(\{ pendingPostUpdateReleaseNotes:/);
});

test("an explicit CCbuddy HTTPS feed enables only production auto-updates", () => {
  const manifestUrl = "https://updates.ccbuddy.example/releases/latest.yml";
  const production = resolveCCbuddyDesktopUpdatePolicy({
    flavor: "production",
    manifestUrl,
  });
  assert.equal(production.autoUpdateEnabled, true);
  assert.deepEqual(production.updateFeedSource, { url: manifestUrl });

  const preview = resolveCCbuddyDesktopUpdatePolicy({ flavor: "preview", manifestUrl });
  assert.equal(preview.autoUpdateEnabled, false);
  assert.equal(preview.updateFeedSource, undefined);
});

test("a malformed or untrusted feed fails closed", () => {
  for (const value of [
    "not-a-url",
    "http://updates.ccbuddy.example/latest.yml",
    "https://u:p@updates.ccbuddy.example/latest.yml",
    "https://updates.ccbuddy.example/latest.yml#fragment",
  ]) {
    assert.throws(() => normalizeCCbuddyUpdateManifestUrl(value));
  }
  assert.equal(normalizeCCbuddyUpdateManifestUrl(""), null);
});
