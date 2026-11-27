// O22 / PV4-14（fork 部分）：fork 与文件撤销的 session 锁只由 availability 下发
// （docs/v4-refactor/02-projection.md「会话锁与行级资格」）。
// 证据层 L3：真实 Write checkpoint + controlled stream running + 受控手动 compact。行级 actions
// 不随锁翻转、命令拒绝、Hook 审核与取消时序由
// apps/ccbuddy-cli/packages/bootstrap/tests/product-projection-session-locks.test.ts 证明。
import { appendFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import {
  TID_V4_FILE_REWIND_CONFIRM_LOCKED,
  TID_V4_FILE_SUMMARY_UNDO_LOCKED,
} from "@ccbuddy/shared/test-ids";
import { releaseControlledReplay } from "#e2e/helpers/controlled-replay";
import { waitForCompactMarkerStatus } from "#e2e/helpers/conversation-session-compact";
import { clearAppData } from "#e2e/helpers/desktop-app";
import { resolveE2ERuntimePath } from "#e2e/helpers/e2e-runtime-paths";
import {
  clickV4Stop,
  getV4ConversationState,
  getV4PaneSnapshot,
  prepareV4ConversationE2E,
  sendV4Prompt,
  switchV4Mode,
  waitForV4ConversationState,
  waitForV4Pane,
  waitForV4TimelineContaining,
} from "#e2e/helpers/v4-conversation";

const CASE_NAME = "conversation-session-v4-session-action-locks";
const RUNTIME_ROOT = resolveE2ERuntimePath(CASE_NAME);
const FILE_PATH = resolveE2ERuntimePath(CASE_NAME, "locks.txt");
const FILE_CONTENT = "session-locks-line-1\nsession-locks-line-2\n";
const WRITE_MARKER = "E2E_SESSION_LOCKS_WRITE";
const RUNNING_MARKER = "E2E_SESSION_LOCKS_RUNNING";
const RUNNING_FIXTURE_ID = "session-locks-running-controlled";
// 锁导致禁用时的固定提示（docs/ui/task-file-change-summary.md），中英两种界面语言。
const LOCKED_HINTS = [
  "会话正在运行或有待处理的请求，完成后可撤销",
  "The session is running or has a pending request. You can undo after it finishes.",
];
const COMPACT_FIXTURE_ID = "session-locks-compact-controlled";
const SURFACE_TIMEOUT_MS = 30_000;
const SURFACE_POLL_MS = 200;

type UndoState = "missing" | "enabled" | "disabled";

interface LockSurface {
  forkButtons: number;
  undo: UndoState;
}

interface ExpectedSurface {
  fork: "present" | "absent";
  undo: Exclude<UndoState, "missing">;
}

describe("O22 fork 与文件撤销的 session 锁", () => {
  afterEach(async () => {
    // 失败时受控流仍挂着、第 2 轮或 compact 仍在运行；stop 会中止上游请求并释放受控流，
    // 避免把 running 状态留给 after 里的清理。
    await stopActiveWorkIfNeeded();
    await rm(RUNTIME_ROOT, { force: true, recursive: true });
  });

  after(async () => {
    await browser.electron.restoreAllMocks();
    await clearAppData();
  });

  it("running 与 compact 期间撤销与 fork 入口只跟随 session 锁", async function () {
    this.timeout(300_000);
    await rm(RUNTIME_ROOT, { force: true, recursive: true });
    await prepareV4ConversationE2E();
    await switchV4Mode("yolo");

    await sendV4Prompt(`${WRITE_MARKER}: create the fixture file.`);
    await waitForV4TimelineContaining(`${WRITE_MARKER}_DONE`, 90_000);
    await waitForFileContent(FILE_CONTENT);
    await waitForIdle("第 1 轮 Write 没有完成");
    const taskId = (await getV4ConversationState()).taskId;
    if (!taskId) throw new Error("第 1 轮完成后没有 taskId");
    await expectSurface({ fork: "present", undo: "enabled" }, "第 1 轮完成后");

    // running：文件撤销被锁，历史轮 fork 不受影响（PV4-08 允许运行中 fork 更早的稳定轮）。
    await sendV4Prompt(`${RUNNING_MARKER}: keep streaming until released.`);
    await waitForV4TimelineContaining(`${RUNNING_MARKER}_PARTIAL`, 30_000);
    await expectSurface({ fork: "present", undo: "disabled" }, "第 2 轮 running 中");
    await expectLockedHintOnHover(SUMMARY_UNDO_SELECTOR, "running 中摘要卡的撤销按钮");
    await releaseControlledReplay(RUNNING_FIXTURE_ID);
    await waitForV4TimelineContaining(`${RUNNING_MARKER}_DONE`, 30_000);
    await waitForIdle("第 2 轮释放后没有完成");
    await expectSurface({ fork: "present", undo: "enabled" }, "第 2 轮完成后");

    // compact：fork 与文件撤销同时被锁，结束后两者恢复。
    await sendV4Prompt("/compact");
    const started = await waitForCompactMarkerStatus("started", "manual");
    await expectSurface({ fork: "absent", undo: "disabled" }, "手动 compact running 中");
    await releaseControlledReplay(COMPACT_FIXTURE_ID);
    await waitForCompactMarkerStatus("completed", "manual", started.inputId);
    await waitForIdle("手动 compact 释放后没有完成");
    await expectSurface({ fork: "present", undo: "enabled" }, "手动 compact 完成后");

    // 解锁后命令侧同样放行：preview 列出 safe 文件，「撤销文件」按钮可用。
    await openDesktopUndoPreview();
    await waitForDesktopSafePreview();
    await waitForConfirmEnabled(true, "解锁后弹窗的撤销文件按钮");

    await closeDesktopUndoPreview();
    expect(await readFile(FILE_PATH, "utf8")).toBe(FILE_CONTENT);
  });

  async function expectSurface(expected: ExpectedSurface, label: string) {
    const desktop = await waitForSurface(
      () => browser.execute(readLockSurfaceInPage),
      expected,
      label,
    );
    await recordSurfaces({ label, expected, desktop });
  }
});

/** 浏览器内执行：只读 DOM，不依赖闭包。 */
function readLockSurfaceInPage(): LockSurface {
  const headerLabels = [
    "Expand changed files",
    "展开已更改文件",
    "Collapse changed files",
    "收起已更改文件",
  ];
  const undoLabels = ["Undo", "撤销"];
  const header = Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find((button) =>
    headerLabels.includes(button.getAttribute("aria-label") ?? ""),
  );
  const undo = Array.from(
    header?.parentElement?.querySelectorAll<HTMLButtonElement>("button[title]") ?? [],
  ).find((button) => undoLabels.includes(button.getAttribute("title") ?? ""));
  return {
    forkButtons: document.querySelectorAll('[data-testid^="v4-fork-"]').length,
    undo: !undo ? "missing" : undo.disabled ? "disabled" : "enabled",
  };
}

function surfaceMatches(surface: LockSurface, expected: ExpectedSurface): boolean {
  const forkMatches =
    expected.fork === "present" ? surface.forkButtons > 0 : surface.forkButtons === 0;
  return forkMatches && surface.undo === expected.undo;
}

async function waitForSurface(
  read: () => Promise<LockSurface>,
  expected: ExpectedSurface,
  label: string,
): Promise<LockSurface> {
  let latest: LockSurface | null = null;
  const deadline = Date.now() + SURFACE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    latest = await read();
    if (surfaceMatches(latest, expected)) return latest;
    await new Promise((resolve) => setTimeout(resolve, SURFACE_POLL_MS));
  }
  throw new Error(`${label}：期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(latest)}`);
}

async function recordSurfaces(entry: {
  label: string;
  expected: ExpectedSurface;
  desktop: LockSurface;
}) {
  const artifactDir = process.env.CCBUDDY_E2E_ARTIFACT_DIR;
  if (!artifactDir) return;
  await appendFile(join(artifactDir, "SAL-surfaces.jsonl"), `${JSON.stringify(entry)}\n`);
}

// 禁用按钮带 pointer-events-none，hover 落在外层的禁用提示 span 上。
const SUMMARY_UNDO_SELECTOR = `[data-testid="${TID_V4_FILE_SUMMARY_UNDO_LOCKED}"]`;
const DIALOG_CONFIRM_SELECTOR = `[data-testid="${TID_V4_FILE_REWIND_CONFIRM_LOCKED}"]`;
const CONFIRM_LABELS = ["撤销文件", "Undo files"];

async function expectLockedHintOnHover(selector: string, label: string) {
  const trigger = await $(selector);
  await trigger.waitForExist({
    timeout: SURFACE_TIMEOUT_MS,
    timeoutMsg: `${label}：没有禁用提示入口`,
  });
  await trigger.moveTo();
  await browser.waitUntil(
    () =>
      browser.execute(
        (hints) =>
          Array.from(document.querySelectorAll<HTMLElement>('[data-slot="tooltip-content"]')).some(
            (tip) => hints.some((hint) => (tip.innerText ?? "").includes(hint)),
          ),
        LOCKED_HINTS,
      ),
    { timeout: SURFACE_TIMEOUT_MS, timeoutMsg: `${label}：hover 后没有显示锁定原因` },
  );
}

/** 读弹窗里「撤销文件」按钮是否可用；找不到按钮时为 null。 */
function readConfirmEnabledInPage(confirmLabels: string[]): boolean | null {
  const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
  const confirm = Array.from(dialog?.querySelectorAll<HTMLButtonElement>("button") ?? []).find(
    (button) => confirmLabels.includes(button.innerText.trim()),
  );
  return confirm ? !confirm.disabled : null;
}

async function waitForConfirmEnabled(enabled: boolean, label: string) {
  let latest: boolean | null = null;
  await browser.waitUntil(
    async () => {
      latest = await browser.execute(readConfirmEnabledInPage, CONFIRM_LABELS);
      return latest === enabled;
    },
    {
      timeout: SURFACE_TIMEOUT_MS,
      timeoutMsg: `${label}：期望${enabled ? "可用" : "禁用"}，实际 ${String(latest)}`,
    },
  );
}

async function stopActiveWorkIfNeeded() {
  if (!(await getV4PaneSnapshot()).canStop) return;
  await clickV4Stop();
  await waitForV4Pane((snapshot) => !snapshot.canStop, "收尾 stop 后仍在运行", 30_000);
}

async function waitForIdle(timeoutMsg: string) {
  await waitForV4ConversationState((snapshot) => snapshot.state === "idle", timeoutMsg, 60_000);
}

async function waitForFileContent(expected: string) {
  await browser.waitUntil(
    async () => (await readFile(FILE_PATH, "utf8").catch(() => "")) === expected,
    { timeout: 60_000, timeoutMsg: `${FILE_PATH} 没有收敛到期望内容` },
  );
}

async function openDesktopUndoPreview() {
  const clicked = await browser.execute(() => {
    const headerLabels = [
      "Expand changed files",
      "展开已更改文件",
      "Collapse changed files",
      "收起已更改文件",
    ];
    const header = Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find(
      (button) => headerLabels.includes(button.getAttribute("aria-label") ?? ""),
    );
    const undo = Array.from(
      header?.parentElement?.querySelectorAll<HTMLButtonElement>("button[title]") ?? [],
    ).find((button) => ["Undo", "撤销"].includes(button.getAttribute("title") ?? ""));
    if (!undo || undo.disabled) return false;
    undo.click();
    return true;
  });
  expect(clicked).toBe(true);
}

async function waitForDesktopSafePreview() {
  await browser.waitUntil(
    () =>
      browser.execute(() => {
        const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
        const text = dialog?.innerText ?? "";
        return /可安全撤销 1|Safe to undo 1/u.test(text);
      }),
    { timeout: SURFACE_TIMEOUT_MS, timeoutMsg: "解锁后文件撤销 preview 没有列出 1 个 safe 文件" },
  );
}

async function closeDesktopUndoPreview() {
  // 文件摘要的撤销弹窗只有“撤销文件”一个按钮，用 Escape 关闭，不触发 apply。
  await browser.keys("Escape");
  await browser.waitUntil(() => browser.execute(() => !document.querySelector('[role="dialog"]')), {
    timeout: SURFACE_TIMEOUT_MS,
    timeoutMsg: "Escape 后文件撤销 preview 没有关闭",
  });
}
