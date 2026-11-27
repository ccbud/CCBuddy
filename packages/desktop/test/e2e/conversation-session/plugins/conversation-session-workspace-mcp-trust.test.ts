import { clickOpenScopeMenuOption } from "#e2e/helpers/settings-scope-menu";
import { type Page } from "playwright-core";
import { setTimeout as pause } from "node:timers/promises";
import {
  startElectronWindowRecording,
  ELECTRON_WINDOW_RECORDING_CAPTURE_MODE,
} from "#e2e/helpers/electron-window-recorder";

import { access, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import {
  TID_CONFIRM_DIALOG_CONFIRM,
  TID_MCP_SERVER_ROW,
  TID_SETTINGS_BACK_BUTTON,
  TID_SETTINGS_PAGE,
  TID_SETTINGS_SECTION_NAV,
  TID_TASK_SETTINGS_BUTTON,
  testId,
} from "@ccbuddy/shared/test-ids";
import {
  clearAppData,
  clickTestIdByDom,
  getE2EAppDataPaths,
  waitForTestIdByDom,
} from "#e2e/helpers/desktop-app";
import { prepareV4ConversationE2E, sendV4Prompt } from "#e2e/helpers/v4-conversation";
import { setPluginPresentation } from "#e2e/helpers/plugin-management-lifecycle";

const paths = getE2EAppDataPaths();
const name = "e2e_workspace_mcp_trust";
const marker = join(paths.workspace, ".mcp-trust-wire.ndjson");
const configPath = join(paths.workspace, ".ccbuddy", "config.json");
const trustPath = join(paths.storageRoot, "security", "workspace-mcp-trust-v1.json");
const rowId = testId(TID_MCP_SERVER_ROW, name);
const pendingTriggerId = "v4-workspace-mcp-pending-trigger";
const pendingPopoverId = "v4-workspace-mcp-pending-popover";
const pendingUnreadId = "v4-workspace-mcp-pending-unread";
const pendingReviewId = "v4-workspace-mcp-pending-review";
const pendingDismissId = "v4-workspace-mcp-pending-dismiss";
let original: string | undefined;
const fallbackPath = join(paths.workspace, ".agents", "mcp.json");
let fallbackOriginal: string | undefined;
let fallbackWritten = false;
// 仅为人工评审保留可读画面；状态就绪仍由下面的断言等待。
const REVIEW_PAUSE_MS = 1_200;

async function exists(path: string) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}
async function waitTrusted(trusted: boolean, targetRowId = rowId) {
  await browser.waitUntil(
    async () =>
      browser.execute(
        (id, expected) => {
          const row = document.querySelector(`[data-testid="${id}"]`);
          return (
            row?.querySelector("[data-mcp-trusted]")?.getAttribute("data-mcp-trusted") ===
            String(expected)
          );
        },
        targetRowId,
        trusted,
      ),
    { timeout: 30_000, timeoutMsg: "MCP trust projection did not update" },
  );
}

// 验证实际高亮后的代码内容与边界；穿过现有 CodeViewer 的 Shadow DOM。
function readTrustCodePresentation() {
  const dialog = document.querySelector<HTMLElement>('[data-confirm-intent="workspace-mcp-trust"]');
  const block = dialog?.querySelector<HTMLElement>('[data-testid="confirm-dialog-code"]');
  if (!dialog || !block) return null;
  const roots: ParentNode[] = [block];
  let code: HTMLElement | null = null;
  while (roots.length && !code) {
    const root = roots.shift()!;
    code = root.querySelector<HTMLElement>("[data-code] [data-content]");
    for (const element of root.querySelectorAll("*")) {
      if (element.shadowRoot) roots.push(element.shadowRoot);
    }
  }
  if (!code) return null;
  const descriptionId = dialog.getAttribute("aria-describedby");
  const description = descriptionId ? document.getElementById(descriptionId) : null;
  let descriptionFits = false;
  const descriptionText = description?.firstChild;
  if (description && descriptionText?.nodeType === Node.TEXT_NODE) {
    // 来源路径允许滚动；首段风险和生效说明必须无需滚动即可完整看到。
    const explanation = document.createRange();
    explanation.selectNodeContents(descriptionText);
    const separator = descriptionText.textContent?.indexOf("\n\n") ?? -1;
    if (separator >= 0) explanation.setEnd(descriptionText, separator);
    descriptionFits =
      explanation.getBoundingClientRect().bottom <= description.getBoundingClientRect().bottom + 1;
  }
  const bounds = dialog.getBoundingClientRect();
  const confirm = dialog
    .querySelector<HTMLElement>('[data-testid="confirm-dialog-confirm"]')
    ?.getBoundingClientRect();
  return {
    text: Array.from(
      code.querySelectorAll("[data-line]"),
      (line) => line.textContent?.trimEnd() ?? "",
    ).join("\n"),
    highlighted: code.querySelectorAll("span[style]").length > 0,
    fits:
      bounds.left >= 0 &&
      bounds.right <= innerWidth + 1 &&
      bounds.top >= 0 &&
      bounds.bottom <= innerHeight + 1 &&
      dialog.scrollWidth <= dialog.clientWidth + 1,
    confirmVisible: Boolean(confirm && confirm.top >= 0 && confirm.bottom <= innerHeight),
    descriptionFits,
  };
}

async function openMcpPendingPopover(page?: Page) {
  if (page) {
    await page.getByTestId(pendingTriggerId).click();
    await page.getByTestId(pendingPopoverId).waitFor({ state: "visible" });
  } else {
    await browser.$(`[data-testid="${pendingTriggerId}"]`).click();
    await browser.$(`[data-testid="${pendingPopoverId}"]`).waitForDisplayed();
  }
}

async function reviewTrustCode(page?: Page) {
  const read = () =>
    page ? page.evaluate(readTrustCodePresentation) : browser.execute(readTrustCodePresentation);
  await browser.waitUntil(async () => Boolean((await read())?.highlighted), {
    timeout: 15_000,
    timeoutMsg: "Trust JSON syntax highlighting did not render",
  });
  const view = (await read())!;
  expect(JSON.parse(view.text).command).toBe(
    `${process.execPath} ${resolve(process.cwd(), "test/e2e/fixtures/mcp/dual-era-version-server.mjs")}`,
  );
  expect(view.text).toContain('\n  "command"');
  expect(view.fits).toBe(true);
  expect(view.confirmVisible).toBe(true);
  expect(view.descriptionFits).toBe(true);
}

describe("WMT-01 workspace MCP manual trust", () => {
  afterEach(async function () {
    const artifactDir = process.env.CCBUDDY_E2E_ARTIFACT_DIR;
    if (artifactDir && this.currentTest?.state === "failed") {
      const caseMarker = this.currentTest.title.match(/^WMT-\d+/u)?.[0] ?? "WMT-01";
      await browser.saveScreenshot(join(artifactDir, `${caseMarker}-desktop-failure.png`));
      await writeFile(
        join(artifactDir, `${caseMarker}-desktop-dom.txt`),
        await browser.execute(() => document.body.innerText),
      );
    }
  });
  after(async () => {
    if (original !== undefined) await writeFile(configPath, original);
    else await rm(configPath, { force: true });
    if (fallbackWritten) {
      if (fallbackOriginal !== undefined) await writeFile(fallbackPath, fallbackOriginal);
      else await rm(fallbackPath, { force: true });
    }
    await browser.electron.restoreAllMocks();
    await clearAppData();
  });
  it("WMT-01/04: session guidance, exact trust and revoke preserve MCP admission", async function () {
    this.timeout(180_000);
    await prepareV4ConversationE2E();
    if (await exists(configPath)) original = await readFile(configPath, "utf8");
    await mkdir(dirname(configPath), { recursive: true });
    await rm(marker, { force: true });
    const config = original ? JSON.parse(original) : {};
    config.mcp = {
      ...config.mcp,
      servers: {
        ...config.mcp?.servers,
        [name]: {
          type: "stdio",
          command: process.execPath,
          args: [resolve(process.cwd(), "test/e2e/fixtures/mcp/dual-era-version-server.mjs")],
          protocolVersion: "legacy",
          env: { E2E_MCP_VERSION_MODE: "legacy", E2E_MCP_VERSION_WIRE_LOG: marker },
        },
      },
    };
    await writeFile(configPath, JSON.stringify(config));
    const artifactDir = process.env.CCBUDDY_E2E_ARTIFACT_DIR;
    if (!artifactDir) throw new Error("isolated artifact directory required");
    await setPluginPresentation({ locale: "zh-CN", theme: "zai-light", width: 1280, height: 660 });
    const recording = await startElectronWindowRecording({
      outputPath: join(artifactDir, "WMT-01-desktop-full-flow.mp4"),
      frameIntervalMs: 200,
      preRollDurationMs: 1_000,
    });
    try {
      await sendV4Prompt("E2E_MCP_TRUST_GUIDANCE first: reply with ok");
      await browser.waitUntil(
        async () =>
          browser.execute(() => document.body.innerText.includes("MCP guidance first ready")),
        { timeout: 30_000 },
      );
      await waitForTestIdByDom(pendingTriggerId);
      await waitForTestIdByDom(pendingUnreadId);
      expect(await browser.$(`[data-testid="${pendingPopoverId}"]`).isExisting()).toBe(false);
      await openMcpPendingPopover();
      expect(await browser.$(`[data-testid="${pendingUnreadId}"]`).isExisting()).toBe(false);
      expect(await browser.$(`[data-testid="${pendingPopoverId}"]`).getText()).toContain(
        "信任变更在新建或重启会话时生效",
      );
      expect(await exists(marker)).toBe(false);
      await browser.saveScreenshot(join(artifactDir, "WMT-04-session-pending.png"));
      await pause(REVIEW_PAUSE_MS);
      await browser.keys("Escape");
      await browser.$(`[data-testid="${pendingPopoverId}"]`).waitForExist({ reverse: true });
      expect(await browser.$(`[data-testid="${pendingTriggerId}"]`).isExisting()).toBe(true);
      expect(await browser.$(`[data-testid="${pendingTriggerId}"]`).isFocused()).toBe(true);
      await openMcpPendingPopover();
      await clickTestIdByDom(pendingDismissId);
      await browser.$(`[data-testid="${pendingTriggerId}"]`).waitForExist({ reverse: true });
      // 声明变化由下一条用户输入触发重读；普通模型续步不再承担提示刷新。
      config.mcp.servers[name].env.E2E_MCP_GUIDANCE_REVISION = "2";
      await writeFile(configPath, JSON.stringify(config));
      expect(await browser.$(`[data-testid="${pendingTriggerId}"]`).isExisting()).toBe(false);
      await sendV4Prompt("E2E_MCP_TRUST_GUIDANCE changed: reply with ok");
      await browser.waitUntil(
        async () =>
          browser.execute(() => document.body.innerText.includes("MCP guidance changed ready")),
        { timeout: 30_000 },
      );
      await waitForTestIdByDom(pendingTriggerId);
      await waitForTestIdByDom(pendingUnreadId);
      await openMcpPendingPopover();
      await clickTestIdByDom(pendingReviewId);
      await waitForTestIdByDom(TID_SETTINGS_PAGE);
      await waitForTestIdByDom(rowId);
      await waitTrusted(false);
      // 设置页已有「用户」选择时，审核意图仍须回到这条会话的工作区。
      await browser.$('[data-testid="plugin-settings-scope-trigger"]').click();
      await clickOpenScopeMenuOption("user");
      await browser.$(`[data-testid="${rowId}"]`).waitForExist({ reverse: true });
      await clickTestIdByDom(TID_SETTINGS_BACK_BUTTON);
      await openMcpPendingPopover();
      await clickTestIdByDom(pendingReviewId);
      await waitForTestIdByDom(rowId);
      await waitTrusted(false);
      expect(await exists(marker)).toBe(false);
      await pause(REVIEW_PAUSE_MS);
      for (const [locale, theme] of [
        ["zh-CN", "zai-dark"],
        ["en-US", "zai-light"],
      ] as const) {
        await setPluginPresentation({ locale, theme, width: 1280, height: 660 });
        await waitTrusted(false);
        await browser.saveScreenshot(join(artifactDir, `WMT-01-${locale}-${theme}.png`));
        await pause(REVIEW_PAUSE_MS);
      }
      await setPluginPresentation({
        locale: "zh-CN",
        theme: "zai-light",
        width: 1280,
        height: 660,
      });
      await clickTestIdByDom(testId("mcp-workspace-trust", name));
      await pause(REVIEW_PAUSE_MS);
      await reviewTrustCode();
      const copyButton = browser.$('[data-testid="confirm-dialog-code"] button');
      await copyButton.click();
      await reviewTrustCode();
      await browser.execute(() =>
        document
          .querySelector<HTMLButtonElement>('[data-testid="confirm-dialog-code"] button')
          ?.focus(),
      );
      await browser.keys("Enter");
      await reviewTrustCode();
      await waitTrusted(false);
      for (const theme of ["zai-dark", "zai-light"] as const) {
        await setPluginPresentation({ locale: "zh-CN", theme, width: 1280, height: 660 });
        await reviewTrustCode();
        await browser.saveScreenshot(join(artifactDir, `WMT-01-json-${theme}.png`));
        await pause(REVIEW_PAUSE_MS);
      }
      await pause(REVIEW_PAUSE_MS);
      await browser.saveScreenshot(join(artifactDir, "WMT-01-review.png"));
      await clickTestIdByDom(TID_CONFIRM_DIALOG_CONFIRM);
      await waitTrusted(true);
      const store = JSON.parse(await readFile(trustPath, "utf8"));
      expect(
        store.records.some((record: { serverName: string }) => record.serverName === name),
      ).toBe(true);
      expect(await exists(marker)).toBe(false);
      await clickTestIdByDom(TID_SETTINGS_BACK_BUTTON);
      await browser.$(`[data-testid="${pendingTriggerId}"]`).waitForExist({ reverse: true });
      await clickTestIdByDom(TID_TASK_SETTINGS_BUTTON);
      await browser.$('[data-testid="plugin-settings-scope-trigger"]').click();
      await clickOpenScopeMenuOption(paths.workspace);
      await waitForTestIdByDom(rowId);
      await pause(REVIEW_PAUSE_MS);
      await clickTestIdByDom("mcp-settings-refresh");
      await browser.waitUntil(
        async () =>
          (await exists(marker)) &&
          (await readFile(marker, "utf8")).includes('"method":"tools/list"'),
        { timeout: 30_000, timeoutMsg: "Trusted MCP did not handshake" },
      );
      await browser.waitUntil(
        async () =>
          (await browser.$(`[data-testid="${rowId}"]`).getAttribute("data-mcp-status")) ===
          "connected",
        { timeout: 30_000, timeoutMsg: "Connected MCP status did not reach the UI" },
      );
      await pause(REVIEW_PAUSE_MS);
      await clickTestIdByDom(testId("mcp-workspace-trust", name));
      await pause(REVIEW_PAUSE_MS);
      await clickTestIdByDom(TID_CONFIRM_DIALOG_CONFIRM);
      await waitTrusted(false);
      const revoked = JSON.parse(await readFile(trustPath, "utf8"));
      expect(
        revoked.records.some((record: { serverName: string }) => record.serverName === name),
      ).toBe(false);
      await pause(REVIEW_PAUSE_MS);
    } finally {
      const video = await recording.stop({ tailDurationMs: 1_000 });
      await writeFile(
        join(artifactDir, "WMT-01-video.json"),
        JSON.stringify(
          {
            video_capture_mode: ELECTRON_WINDOW_RECORDING_CAPTURE_MODE,
            frameCount: video.frameCount,
            captureError: video.captureError,
            file: "WMT-01-desktop-full-flow.mp4",
          },
          null,
          2,
        ),
      );
      expect(video.captureError).toBeUndefined();
    }
  });
  it("WMT-03: deleting the final project entry exposes a trustable fallback beside invalid config", async function () {
    this.timeout(180_000);
    const artifactDir = process.env.CCBUDDY_E2E_ARTIFACT_DIR;
    if (!artifactDir) throw new Error("isolated artifact directory required");
    const fallbackName = "e2e_workspace_mcp_fallback";
    const fallbackRowId = testId(TID_MCP_SERVER_ROW, fallbackName);
    const fallbackMarker = join(paths.workspace, ".mcp-fallback-wire.ndjson");
    const invalidMarker = join(paths.workspace, ".mcp-invalid-wire.ndjson");
    if (await exists(fallbackPath)) fallbackOriginal = await readFile(fallbackPath, "utf8");
    await mkdir(dirname(fallbackPath), { recursive: true });
    await rm(fallbackMarker, { force: true });
    await rm(invalidMarker, { force: true });
    await writeFile(
      fallbackPath,
      JSON.stringify({
        mcpServers: {
          [fallbackName]: {
            type: "stdio",
            command: process.execPath,
            args: [resolve(process.cwd(), "test/e2e/fixtures/mcp/dual-era-version-server.mjs")],
            protocolVersion: "legacy",
            isolation: "session",
            environment: {
              E2E_MCP_VERSION_MODE: "legacy",
              E2E_MCP_VERSION_WIRE_LOG: fallbackMarker,
            },
          },
          e2e_invalid_neighbor: {
            type: "stdio",
            command: process.execPath,
            args: [resolve(process.cwd(), "test/e2e/fixtures/mcp/dual-era-version-server.mjs")],
            env: { E2E_MCP_VERSION_MODE: "legacy", E2E_MCP_VERSION_WIRE_LOG: invalidMarker },
            description: "unsupported metadata",
          },
        },
      }),
    );
    fallbackWritten = true;
    const recording = await startElectronWindowRecording({
      outputPath: join(artifactDir, "WMT-03-fallback-full-flow.mp4"),
      frameIntervalMs: 200,
    });
    try {
      await setPluginPresentation({
        locale: "zh-CN",
        theme: "zai-light",
        width: 1280,
        height: 660,
      });
      await clickTestIdByDom(TID_TASK_SETTINGS_BUTTON);
      await waitForTestIdByDom(TID_SETTINGS_PAGE);
      await clickTestIdByDom(testId(TID_SETTINGS_SECTION_NAV, "mcp"));
      await browser.$('[data-testid="plugin-settings-scope-trigger"]').click();
      await clickOpenScopeMenuOption(paths.workspace);
      await waitForTestIdByDom(rowId);
      expect(Object.keys(JSON.parse(await readFile(configPath, "utf8")).mcp.servers)).toEqual([
        name,
      ]);
      await clickTestIdByDom(rowId);
      await browser.$("button=删除").click();
      await clickTestIdByDom(TID_CONFIRM_DIALOG_CONFIRM);
      await browser.waitUntil(
        async () =>
          Object.keys(JSON.parse(await readFile(configPath, "utf8")).mcp.servers).length === 0,
        { timeout: 15_000 },
      );
      // 删除只移除当前缓存行；通过真实刷新入口重读目录，发现 fallback 配置。
      await clickTestIdByDom("mcp-settings-refresh");
      await waitForTestIdByDom(fallbackRowId);
      await waitTrusted(false, fallbackRowId);
      expect(await exists(fallbackMarker)).toBe(false);
      await pause(REVIEW_PAUSE_MS);
      await browser.saveScreenshot(join(artifactDir, "WMT-03-fallback-pending.png"));
      await clickTestIdByDom(testId("mcp-workspace-trust", fallbackName));
      await reviewTrustCode();
      await pause(REVIEW_PAUSE_MS);
      await clickTestIdByDom(TID_CONFIRM_DIALOG_CONFIRM);
      await waitTrusted(true, fallbackRowId);
      expect(await exists(fallbackMarker)).toBe(false);
      await clickTestIdByDom("mcp-settings-refresh");
      await browser.waitUntil(
        async () =>
          (await exists(fallbackMarker)) &&
          (await readFile(fallbackMarker, "utf8")).includes('"method":"tools/list"'),
        {
          timeout: 30_000,
          timeoutMsg: "Fallback MCP environment did not reach the real handshake",
        },
      );
      await browser.waitUntil(
        async () =>
          (await browser.$(`[data-testid="${fallbackRowId}"]`).getAttribute("data-mcp-status")) ===
          "connected",
        { timeout: 30_000 },
      );
      // 无效声明没有审核摘要；验证无法批准和零启动，不把 UI 的 unknown 投影当成准入状态。
      expect(
        await browser
          .$(`[data-testid="${testId("mcp-workspace-trust", "e2e_invalid_neighbor")}"]`)
          .isEnabled(),
      ).toBe(false);
      const invalidRow = browser.$(
        `[data-testid="${testId(TID_MCP_SERVER_ROW, "e2e_invalid_neighbor")}"]`,
      );
      expect(await invalidRow.getAttribute("data-mcp-status")).toBe("untrusted");
      expect(await invalidRow.getText()).toContain("当前声明待信任");
      expect(await invalidRow.getText()).not.toContain("重启 Agent");
      expect(await exists(invalidMarker)).toBe(false);
      await pause(REVIEW_PAUSE_MS);
      await browser.saveScreenshot(join(artifactDir, "WMT-03-fallback-connected.png"));
    } finally {
      const video = await recording.stop({ tailDurationMs: 1_000 });
      expect(video.captureError).toBeUndefined();
    }
  });
});
