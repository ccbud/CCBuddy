import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { rendererHtmlFileName, resolveRendererDevUrl } from "../src/main/desktopRendererPage.ts";

const desktopRoot = resolve(import.meta.dirname, "..");

test("session history uses the main renderer entry in dev and packaged modes", async () => {
  assert.equal(
    resolveRendererDevUrl("http://127.0.0.1:5173/", "index").href,
    "http://127.0.0.1:5173/",
  );
  assert.equal(rendererHtmlFileName("index"), "index.html");

  const html = await readFile(join(desktopRoot, "src", "renderer", "index.html"), "utf8");
  const entry = await readFile(join(desktopRoot, "src", "renderer", "src", "mainEntry.ts"), "utf8");
  const viteConfig = await readFile(join(desktopRoot, "vite.config.ts"), "utf8");
  assert.match(html, /src="\.\/src\/mainEntry\.ts"/u);
  assert.match(entry, /import\("\.\/main\.js"\)/u);
  assert.doesNotMatch(viteConfig, /history\.html/u);
});
