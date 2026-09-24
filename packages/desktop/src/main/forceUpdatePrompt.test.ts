import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  readForceUpdatePromptIcon,
  renderForceUpdatePromptHtml,
  resolveForceUpdatePromptIconPath,
} from "./forceUpdatePrompt.js";

const dialogText = {
  title: "更新 CCbuddy",
  message: "请安装更新",
  detail: "2.0.11 → 2.0.12",
  autoUpdateButton: "自动更新",
  manualUpdateButton: "手动更新",
  quitButton: "退出",
};

test("forced-update prompt reads the packaged CCbuddy icon from resources", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-update-brand-"));
  t.after(async () => rm(root, { recursive: true, force: true }));
  const resourcesPath = join(root, "resources");
  await mkdir(resourcesPath);
  const iconBytes = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLytAAAAABJRU5ErkJggg==",
    "base64",
  );
  await writeFile(join(resourcesPath, "ccbuddy-about-icon.png"), iconBytes);

  const iconPath = resolveForceUpdatePromptIconPath(true, resourcesPath);
  assert.equal(iconPath, join(resourcesPath, "ccbuddy-about-icon.png"));
  const iconDataUrl = await readForceUpdatePromptIcon(iconPath);
  assert.equal(iconDataUrl, `data:image/png;base64,${iconBytes.toString("base64")}`);

  const html = renderForceUpdatePromptHtml(dialogText, "zh-CN", iconDataUrl);
  assert.match(html, /<img src="data:image\/png;base64,[^"]+" alt="" \/>/);
  assert.match(html, /\.brand-icon img \{[^}]*object-fit: cover/);
});

test("forced-update prompt uses a CCbuddy text fallback when the icon is unavailable", async (t) => {
  const resourcesPath = await mkdtemp(join(tmpdir(), "ccbuddy-update-brand-missing-"));
  t.after(async () => rm(resourcesPath, { recursive: true, force: true }));
  const iconDataUrl = await readForceUpdatePromptIcon(
    resolveForceUpdatePromptIconPath(true, resourcesPath),
  );
  assert.equal(iconDataUrl, null);

  const html = renderForceUpdatePromptHtml(dialogText, "zh-CN", iconDataUrl);
  assert.doesNotMatch(html, /class="brand-icon"/);
  assert.match(html, /<div class="brand-title">CCbuddy<\/div>/);
});

test("development icon path resolves beside the desktop source or build", () => {
  const mainModuleDirectory = join(tmpdir(), "ccbuddy", "packages", "desktop", "out", "main");
  const iconPath = resolveForceUpdatePromptIconPath(
    false,
    "/unused-resources",
    mainModuleDirectory,
  );
  assert.equal(iconPath, join(mainModuleDirectory, "../../build/icons/128x128.png"));
});
