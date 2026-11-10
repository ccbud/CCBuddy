import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import { build } from "esbuild";

const runFile = promisify(execFile);
const root = resolve(import.meta.dirname, "../../..");
const requireDesktop = createRequire(new URL("../package.json", import.meta.url));

test(
  "real Electron exits after one asynchronous updater handoff",
  { timeout: 60_000 },
  async (context) => {
    const directory = await mkdtemp(resolve(tmpdir(), "ccbuddy-update-quit-"));
    context.after(() => rm(directory, { recursive: true, force: true }));
    const entry = resolve(directory, "main.cjs");
    await build({
      stdin: {
        contents: `
        import { app, ipcMain } from "electron";
        import updater from "electron-updater";
        import { initAutoUpdater } from ${JSON.stringify(resolve(root, "packages/desktop/src/main/autoUpdater.ts"))};
        import { PlatformChannels } from ${JSON.stringify(resolve(root, "packages/shared/src/index.ts"))};
        app.setPath("userData", ${JSON.stringify(directory)});
        Object.defineProperty(app, "isPackaged", { value: true });
        let preparations = 0;
        let nativeQuits = 0;
        app.whenReady().then(async () => {
          await initAutoUpdater({ onBeforeQuitAndInstall: async () => { preparations++; } });
          updater.autoUpdater.emit("update-downloaded", { version: "99.0.0" });
          app.on("before-quit", (event) => {
            nativeQuits++;
            if (event.defaultPrevented) {
              process.stderr.write("Native quit was prevented after installer handoff\\n");
              app.exit(1);
            }
          });
          app.on("will-quit", () => {
            process.stdout.write(JSON.stringify({
              preparations, nativeQuits, installs: updater.autoUpdater.installs,
            }) + "\\n");
          });
          ipcMain.emit(PlatformChannels.QuitAndInstallUpdate);
        }).catch((error) => { process.stderr.write(String(error)); app.exit(1); });
      `,
        resolveDir: root,
        sourcefile: "update-quit-fixture.mjs",
      },
      outfile: entry,
      bundle: true,
      platform: "node",
      format: "cjs",
      target: "node24",
      external: ["electron"],
      logLevel: "silent",
      plugins: [
        {
          name: "controlled-installer-ports",
          setup(builder) {
            builder.onResolve({ filter: /^electron-updater$/ }, () => ({
              path: "updater",
              namespace: "fixture",
            }));
            builder.onResolve({ filter: /^\.\/(logger|manifestUpdateProvider)\.js$/ }, (args) => {
              if (!args.importer.endsWith("/autoUpdater.ts")) return;
              return { path: args.path, namespace: "fixture" };
            });
            builder.onLoad({ filter: /.*/, namespace: "fixture" }, (args) => ({
              contents:
                args.path === "updater"
                  ? `
            import { EventEmitter } from "node:events";
            import { app } from "electron";
            const autoUpdater = Object.assign(new EventEmitter(), {
              installs: 0,
              setFeedURL() {},
              async checkForUpdates() {},
              quitAndInstall() { this.installs++; setImmediate(() => app.quit()); },
            });
            export class CancellationToken {}
            export default { autoUpdater };
          `
                  : args.path.includes("manifestUpdateProvider")
                    ? `
            export class ManifestUpdateProvider {}
            export const getElectronReleasePlatform = () => "darwin-arm64";
          `
                    : "export const logger = { info() {}, warn() {}, error() {} };",
              resolveDir: root,
            }));
          },
        },
      ],
    });
    const env = { ...process.env };
    delete env.ELECTRON_RUN_AS_NODE;
    const { stdout } = await runFile(requireDesktop("electron"), [entry], {
      env,
      timeout: 45_000,
    });
    const summary = stdout.split(/\r?\n/).find((line) => line.startsWith('{"preparations":'));
    assert.ok(summary, "Electron must reach will-quit and report the handoff result");
    assert.deepEqual(JSON.parse(summary), { preparations: 1, nativeQuits: 1, installs: 1 });
  },
);
