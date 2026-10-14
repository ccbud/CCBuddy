import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

const uiRoot = new URL("../src/", import.meta.url);
const webRoot = new URL("../../web/src/", import.meta.url);
async function listSources(root) {
  const entries = await readdir(root, { withFileTypes: true });
  const sources = await Promise.all(
    entries.map(async (entry) => {
      const item = new URL(entry.name + (entry.isDirectory() ? "/" : ""), root);
      if (entry.isDirectory()) return listSources(item);
      return /\.[cm]?[jt]sx?$/.test(entry.name) && !/\.test\./.test(entry.name) ? [item] : [];
    }),
  );
  return sources.flat();
}

test("mobile remote control has no UI or Web implementation or public entry", async () => {
  for (const source of [...(await listSources(uiRoot)), ...(await listSources(webRoot))]) {
    const contents = await readFile(source, "utf8");
    assert.doesNotMatch(
      contents,
      /WebRemoteControl|webRemoteControl|web-remote-control|remoteControlToken|REMOTE_CONTROL|mobilePlanInteraction|MobilePlanInteraction|data-mobile-active-task/,
      path.relative(process.cwd(), source.pathname),
    );
  }
});

test("ordinary Web server and history remain available after retirement", async () => {
  const main = await readFile(new URL("main.tsx", webRoot), "utf8");
  assert.match(main, /connectViaWebSocket/);
  assert.match(main, /\/api\/server-info/);
  assert.match(main, /ConversationShareLandingLoader/);
  const sidebar = await readFile(new URL("WorkspaceSidebar.tsx", uiRoot), "utf8");
  assert.match(sidebar, /HistorySidebarButton/);
});
