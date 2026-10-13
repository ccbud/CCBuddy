import assert from "node:assert/strict";
import { readFile, access } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { test } from "node:test";

const root = resolve(import.meta.dirname, "../..");

for (const entry of ["packages/desktop/src/renderer/index.html", "packages/web/index.html"]) {
  test(`${entry} presents the shipped CCbuddy artwork before React loads`, async () => {
    const path = resolve(root, entry);
    const html = await readFile(path, "utf8");
    const image = html.match(
      /<img\b[^>]*class="(?:startup-logo|ccbuddy-boot-loading__logo)"[^>]*>/s,
    )?.[0];
    assert.ok(image, "The HTML startup shell must load the CCbuddy image");
    const source = image.match(/src="([^"]+)"/)?.[1];
    assert.ok(source?.endsWith("ccbuddy-icon.png"));
    await access(resolve(dirname(path), source));
    assert.match(image, /alt="CCbuddy"/);
    assert.doesNotMatch(html, /viewBox="0 0 256 218"/);
  });
}
