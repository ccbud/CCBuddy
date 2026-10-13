import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";

const source = await readFile(
  new URL("../src/main/desktopApplicationMenu.ts", import.meta.url),
  "utf8",
);
const tree = ts.createSourceFile("desktopApplicationMenu.ts", source, ts.ScriptTarget.Latest, true);
const functions = [
  "resolveMenuAccelerator",
  "buildApplicationMenuTemplate",
  "rebuildApplicationMenu",
];
const declarations = tree.statements.filter(
  (node) => ts.isFunctionDeclaration(node) && functions.includes(node.name?.text),
);
assert.equal(declarations.length, functions.length);
const script = ts.transpileModule(declarations.map((node) => node.getText(tree)).join("\n"), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;

test("native Session History command invokes the existing main-window navigation callback", () => {
  let template;
  let navigationCount = 0;
  const context = {
    exports: {},
    app: { name: "CCbuddy", isPackaged: true },
    process: { platform: process.platform },
    Menu: {
      buildFromTemplate: (value) => {
        template = value;
        return value;
      },
      setApplicationMenu: () => {},
    },
    CCBUDDY_ENV: "production",
    CCBUDDY_PRODUCT_FLAVOR: "production",
    DesktopCommandIds: {},
    desktopMenuMessageIds: new Proxy({}, { get: (_target, key) => key }),
    getDesktopMenuLabel: (_locale, id) => id,
    readCCbuddyStdioTapDevState: () => ({ enabled: false, visible: false }),
    setAutoUpdaterMenuLocale: () => {},
    clampDesktopZoomLevel: (value) => value,
    DESKTOP_ZOOM_MIN_LEVEL: -3,
    DESKTOP_ZOOM_MAX_LEVEL: 3,
    isValidShortcutBinding: () => true,
    CHECK_FOR_UPDATE_MENU_ID: "check-for-update",
    HELP_TOGGLE_CCBUDDY_STDIO_TAP_MENU_ID: "stdio-tap",
    HELP_TOGGLE_DEV_TOOLS_MENU_ID: "dev-tools",
  };
  runInNewContext(script, context);
  context.exports.rebuildApplicationMenu({
    currentApplicationLocale: "en-US",
    openHistoryReview: () => {
      navigationCount += 1;
    },
    executeDesktopCommand: async () => {
      throw new Error("history must use its existing route callback");
    },
  });
  const view = template.find((item) => item.label === "view");
  const history = view.submenu.find((item) => item.label === "Session History");
  assert.ok(history, "the integration must preserve CCbuddy's native history menu item");
  assert.equal(history.accelerator, "CmdOrCtrl+Shift+H");
  history.click();
  assert.equal(navigationCount, 1);
});
