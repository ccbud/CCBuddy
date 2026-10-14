import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { copyFile, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { build } from "esbuild";

// 隔离 renderer 交互回归：真实侧栏、导航 hooks 与历史 controller；不启动完整 Desktop Host。
const require = createRequire(import.meta.url);
const root = resolve(import.meta.dirname, "../../..");
const desktop = join(root, "packages/desktop");
const output = await mkdtemp(join(tmpdir(), "ccbuddy-history-entry-e2e-"));
const cssFiles = (await readdir(join(desktop, "out/renderer/assets"))).filter((name) =>
  name.endsWith(".css"),
);
assert.ok(cssFiles.length, "Build the desktop renderer before running this fixture");
await Promise.all(
  cssFiles.map((name) => copyFile(join(desktop, "out/renderer/assets", name), join(output, name))),
);
await build({
  entryPoints: [join(root, "packages/ui/test/history-entry.fixture.tsx")],
  outfile: join(output, "renderer.js"),
  bundle: true,
  platform: "browser",
  format: "iife",
  jsx: "automatic",
  alias: { "@": join(root, "packages/ui/src") },
  loader: { ".png": "dataurl", ".svg": "dataurl" },
  define: {
    "process.env.NODE_ENV": '"production"',
    "import.meta.env": '{"DEV":false,"PROD":true,"BASE_URL":"./"}',
  },
  logLevel: "warning",
});
await writeFile(
  join(output, "index.html"),
  `<!doctype html><html><head><meta charset="utf-8"><title>CCbuddy history renderer fixture</title>${cssFiles.map((name) => `<link rel="stylesheet" href="${name}">`).join("")}</head><body><div id="root"></div><script src="renderer.js"></script></body></html>`,
);
await writeFile(
  join(output, "preload.cjs"),
  `const {contextBridge, ipcRenderer} = require("electron");
contextBridge.exposeInMainWorld("historyEntryHarness", {
  onHistoryRequested(listener) { const handler = (_, view) => listener(view); ipcRenderer.on("fixture-history-open", handler); return () => ipcRenderer.removeListener("fixture-history-open", handler); },
  requestHistory(view) { return ipcRenderer.invoke("fixture-history-request", view); },
});`,
);
await writeFile(
  join(output, "main.cjs"),
  `const {app, BrowserWindow, ipcMain} = require("electron"); const path = require("node:path");
app.setPath("userData", path.join(__dirname, "profile"));
app.whenReady().then(async () => {
  const win = new BrowserWindow({width:1200,height:840,show:true,webPreferences:{preload:path.join(__dirname,"preload.cjs")}});
  ipcMain.handle("fixture-history-request", (_, view) => { if (view !== "list" && view !== "timeline") throw new Error("Invalid history view"); win.webContents.send("fixture-history-open", view); });
  await win.loadFile(path.join(__dirname,"index.html"));
}); app.on("window-all-closed", () => app.quit());`,
);
const server = createServer();
await new Promise((done, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", done);
});
const port = server.address().port;
await new Promise((done) => server.close(done));
const electron = spawn(
  require("electron"),
  [join(output, "main.cjs"), `--remote-debugging-port=${port}`],
  {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "" },
    stdio: ["ignore", "pipe", "pipe"],
  },
);
let electronLog = "";
electron.stdout.on("data", (value) => {
  electronLog += value;
});
electron.stderr.on("data", (value) => {
  electronLog += value;
});
const browser = (...args) =>
  promisify(execFile)("agent-browser", ["--session", `history-entry-${process.pid}`, ...args], {
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
  });
try {
  // 等待 CDP 的就绪事件，不用固定延迟掩盖启动失败。
  await new Promise((done, reject) => {
    const timeout = setTimeout(
      () => reject(new Error(`Electron CDP startup failed: ${electronLog}`)),
      20_000,
    );
    const check = () => {
      if (electronLog.includes("DevTools listening on")) {
        clearTimeout(timeout);
        electron.stderr.off("data", check);
        done();
      }
    };
    electron.stderr.on("data", check);
    electron.once("error", reject);
    electron.once("exit", (code) => reject(new Error(`Electron exited before CDP: ${code}`)));
    check();
  });
  await browser("connect", String(port));
  await browser("wait", '[data-testid="history-list-sidebar-open"]');
  await writeFile(join(output, "initial-snapshot.txt"), (await browser("snapshot", "-i")).stdout);
  await browser("click", '[data-testid="history-list-sidebar-open"]');
  await browser("wait", '[aria-label="Filter by title, project, or path"]');
  await browser(
    "eval",
    `if(document.querySelector('#workspace').dataset.view !== 'history-list' || document.querySelector('[data-testid="history-list-sidebar-open"]').getAttribute('aria-pressed') !== 'true') throw new Error('Sidebar list navigation failed')`,
  );
  await writeFile(join(output, "list-snapshot.txt"), (await browser("snapshot", "-i")).stdout);
  await browser("click", '[role="option"]');
  await browser("wait", "--text", "Read-only history content from the renderer fixture.");
  await browser("screenshot", join(output, "history-list.png"));
  await browser("click", '[data-testid="history-timeline-sidebar-open"]');
  await browser("wait", '[data-testid="history-timeline-scroll"]');
  await browser(
    "eval",
    `if(document.querySelector('#workspace').dataset.view !== 'history-timeline') throw new Error('Sidebar timeline navigation failed')`,
  );
  await browser("click", '[data-testid="fixture-open-settings"]');
  await browser("wait", "--text", "Settings fixture");
  await browser("eval", `window.historyEntryHarness.requestHistory('timeline')`);
  await browser("wait", '[data-testid="history-timeline-scroll"]');
  await browser(
    "eval",
    `if(document.querySelector('#workspace').dataset.view !== 'history-timeline' || document.querySelector('#workspace').dataset.visible !== 'true') throw new Error('Same-route native navigation lost history on Settings exit')`,
  );
  await browser("screenshot", join(output, "history-native-settings-exit.png"));
  await browser("click", '[data-testid="fixture-open-settings"]');
  await browser("wait", "--text", "Settings fixture");
  await browser("eval", `window.historyEntryHarness.requestHistory('list')`);
  await browser("wait", '[aria-label="Filter by title, project, or path"]');
  await browser(
    "eval",
    `if(document.querySelector('#workspace').dataset.view !== 'history-list') throw new Error('Native list navigation failed')`,
  );
  await writeFile(join(output, "final-snapshot.txt"), (await browser("snapshot", "-i")).stdout);
  process.stdout.write(`History renderer interaction E2E passed. Artifacts: ${output}\n`);
} finally {
  await writeFile(join(output, "electron.log"), electronLog);
  await browser("close").catch(() => {});
  electron.kill("SIGTERM");
}
