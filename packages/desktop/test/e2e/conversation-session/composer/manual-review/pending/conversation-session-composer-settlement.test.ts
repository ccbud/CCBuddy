import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DEFAULT_WORKSPACE } from "#e2e/helpers/desktop-app";
import { startDraftFromProject } from "#e2e/helpers/project-sidebar";
import {
  getV4PaneSnapshot,
  prepareV4ConversationE2E,
  selectV4TaskById,
  setV4ComposerText,
  startNewV4Draft,
  waitForV4ComposerText,
  waitForV4Pane,
} from "#e2e/helpers/v4-conversation";

interface ComposerProbe {
  commands: Array<{ commandId: string; sessionId: string }>;
  unknown: string[];
  accepted: string[];
  enters: number;
  frames: Array<{ text: string; placeholder: string | null; sameEditor: boolean }>;
  release(): void;
  restore(): void;
}
declare global {
  interface Window {
    __composerSettlementProbe?: ComposerProbe;
  }
}
const input = '[data-testid="v4-composer-input"]';
const evidence: unknown[] = [];

async function installProbe(hold: boolean) {
  await browser.execute(
    (hold, selector) => {
      const original = MessagePort.prototype.postMessage;
      const held: Array<() => void> = [];
      const listeners = new Map<MessagePort, (event: MessageEvent) => void>();
      const firstEditor = document.querySelector(selector);
      let submitted = false;
      let last = "";
      const decode = (data: unknown) => {
        const bytes =
          data instanceof ArrayBuffer
            ? new Uint8Array(data)
            : ArrayBuffer.isView(data)
              ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
              : null;
        return bytes ? new TextDecoder().decode(bytes) : "";
      };
      const probe: ComposerProbe = {
        commands: [],
        unknown: [],
        accepted: [],
        enters: 0,
        frames: [],
        release() {
          hold = false;
          held.splice(0).forEach((send) => send());
        },
        restore() {
          probe.release();
          observer.disconnect();
          for (const [port, listener] of listeners) port.removeEventListener("message", listener);
          MessagePort.prototype.postMessage = original;
          document.removeEventListener("keydown", onKey, true);
          delete window.__composerSettlementProbe;
        },
      };
      const onKey = (event: KeyboardEvent) => {
        if (event.key === "Enter" && (event.target as Element)?.matches(selector)) {
          submitted = true;
          probe.enters++;
        }
      };
      document.addEventListener("keydown", onKey, true);
      const observer = new MutationObserver(() => {
        if (!submitted) return;
        const editor = document.querySelector<HTMLElement>(selector);
        if (!editor) return;
        const sample = {
          text: editor.innerText,
          placeholder:
            editor.parentElement?.querySelector<HTMLElement>('[aria-hidden="true"]')?.innerText ??
            null,
          sameEditor: editor === firstEditor,
        };
        const signature = JSON.stringify(sample);
        if (signature !== last) {
          last = signature;
          probe.frames.push(sample);
        }
      });
      observer.observe(document.body, { subtree: true, childList: true, characterData: true });
      // 只改变真实命令与查询的先后顺序；回执和投影全部由 Host/CLI 产生。
      MessagePort.prototype.postMessage = function (
        ...args: [unknown, (Transferable[] | StructuredSerializeOptions)?]
      ) {
        if (!listeners.has(this)) {
          const listener = (event: MessageEvent) => {
            const wire = decode(event.data);
            for (const command of probe.commands) {
              if (!wire.includes(command.commandId)) continue;
              if (wire.includes('"result":"unknown"')) probe.unknown.push(command.commandId);
              if (wire.includes('"status":"accepted"')) probe.accepted.push(command.commandId);
            }
          };
          listeners.set(this, listener);
          this.addEventListener("message", listener);
        }
        const wire = decode(args[0]);
        const forward = () => Reflect.apply(original, this, args);
        if (wire.includes("sendConversationCommandV4") && wire.includes('"type":"sendText"')) {
          const commandId = wire.match(/"commandId":"([^"]+)"/)?.[1];
          const sessionId = wire.match(/"sessionId":"([^"]+)"/)?.[1];
          if (!commandId || !sessionId) throw new Error("真实发送缺少命令或会话身份");
          probe.commands.push({ commandId, sessionId });
          if (hold) {
            held.push(forward);
            return;
          }
        }
        forward();
      };
      window.__composerSettlementProbe = probe;
    },
    hold,
    input,
  );
}
async function probe() {
  return browser.execute(() => {
    const value = window.__composerSettlementProbe!;
    return {
      commands: value.commands,
      unknown: value.unknown,
      accepted: value.accepted,
      enters: value.enters,
      frames: value.frames,
    };
  });
}
async function sendOnce(marker: string) {
  await setV4ComposerText(marker);
  await $(input).click();
  await browser.keys("Enter");
}
async function waitUnknown() {
  await browser.waitUntil(async () => (await probe()).unknown.length > 0, {
    timeout: 15_000,
    timeoutMsg: "未观察到先于发送的真实 unknown 查询回执",
  });
}
async function waitComplete() {
  await waitForV4Pane(
    (pane) =>
      pane.sessionId !== "draft" &&
      !pane.canStop &&
      pane.timelineText.includes("composer-settlement-ok"),
    "发送未进入已完成详情",
    45_000,
  );
}

describe("CST Composer 首发结算与提示交接", () => {
  before(async () => {
    await prepareV4ConversationE2E();
  });
  afterEach(async function () {
    if (await browser.execute(() => Boolean(window.__composerSettlementProbe))) {
      evidence.push({
        case: this.currentTest?.title,
        ...(await probe()),
        pane: await getV4PaneSnapshot(),
      });
      await writeFile(
        join(process.env.CCBUDDY_E2E_ARTIFACT_DIR!, "composer-settlement.json"),
        JSON.stringify(evidence, null, 2),
      );
      await browser.saveScreenshot(
        join(process.env.CCBUDDY_E2E_ARTIFACT_DIR!, `composer-settlement-${evidence.length}.png`),
      );
      await browser.execute(() => window.__composerSettlementProbe?.restore());
    }
  });

  it("CST01 单次 Enter 后清空，首发提示不闪回新任务", async function () {
    this.timeout(90_000);
    await installProbe(false);
    await sendOnce("E2E_COMPOSER_SETTLEMENT_NATURAL");
    await waitComplete();
    await waitForV4ComposerText("", "发送后正文残留");
    const result = await probe();
    expect(result.enters).toBe(1);
    expect(result.commands).toHaveLength(1);
    const empty = result.frames.filter((frame) => !frame.text.trim());
    expect(empty.length).toBeGreaterThan(0);
    expect(empty.every((frame) => frame.sameEditor)).toBe(true);
    expect(empty.some((frame) => frame.placeholder?.startsWith("Ask CCbuddy anything"))).toBe(
      false,
    );
  });

  for (const nextInput of [false, true]) {
    it(
      nextInput
        ? "CST03 查询先到时保留发送期间的新输入"
        : "CST02 查询 unknown 不终止正在发送的草稿",
      async function () {
        this.timeout(90_000);
        await startDraftFromProject(DEFAULT_WORKSPACE);
        await installProbe(true);
        await sendOnce(`E2E_COMPOSER_SETTLEMENT_${nextInput ? "NEXT" : "UNKNOWN"}`);
        await waitUnknown();
        if (nextInput) await setV4ComposerText("next unsent draft");
        await browser.execute(() => window.__composerSettlementProbe!.release());
        await waitComplete();
        await waitForV4ComposerText(nextInput ? "next unsent draft" : "", "结算未保留正确正文");
        const result = await probe();
        expect(result.enters).toBe(1);
        expect(result.commands).toHaveLength(1);
      },
    );
  }

  it("CST04 迟到接纳不修改新草稿，原任务不残留已发送正文", async function () {
    this.timeout(90_000);
    await startDraftFromProject(DEFAULT_WORKSPACE);
    await installProbe(true);
    await sendOnce("E2E_COMPOSER_SETTLEMENT_NAVIGATE");
    await browser.waitUntil(async () => (await probe()).commands.length === 1, {
      timeout: 15_000,
      timeoutMsg: "没有截获待释放的首发命令",
    });
    const target = (await probe()).commands[0]!.sessionId;
    await startNewV4Draft();
    await setV4ComposerText("another unsent draft");
    await browser.execute(() => window.__composerSettlementProbe!.release());
    await browser.waitUntil(async () => (await probe()).accepted.length > 0, {
      timeout: 30_000,
      timeoutMsg: "旧发送没有接纳",
    });
    await waitForV4ComposerText("another unsent draft", "旧接纳修改了新草稿");
    await selectV4TaskById(target);
    await waitComplete();
    await waitForV4ComposerText("", "原任务恢复了已发送正文");
  });
});
