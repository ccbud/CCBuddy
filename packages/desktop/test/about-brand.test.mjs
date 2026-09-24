import assert from "node:assert/strict";
import { test } from "node:test";
import { createCustomAboutDialogHtml } from "../src/main/aboutWindow.ts";

const content = {
  applicationName: "CCbuddy",
  appVersion: "2.0.12",
  copyright: "Copyright © 2026 CCbuddy.",
  optimizationLine: "Optimized for Apple Silicon.",
  versionLabel: "version",
  okButtonLabel: "OK",
};

test("About displays the bundled CCbuddy artwork at the full icon size", () => {
  const html = createCustomAboutDialogHtml({
    ...content,
    iconDataUrl: "data:image/png;base64,Y2NidWRkeQ==",
  });
  assert.match(html, /<img class="app-logo" src="data:image\/png;base64,Y2NidWRkeQ==" alt="" \/>/);
  assert.match(html, /\.app-logo \{\s*width: 52px;\s*height: 52px;/);
  assert.doesNotMatch(html, /<svg|CCbuddy Desktop App/);
});

test("About never substitutes an inherited letterform when artwork is unavailable", () => {
  const html = createCustomAboutDialogHtml({ ...content, iconDataUrl: null });
  assert.match(html, /<span class="app-logo-fallback">CCbuddy<\/span>/);
  assert.doesNotMatch(html, /<svg|<img class="app-logo"/);
});
