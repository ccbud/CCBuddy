import assert from "node:assert/strict";
import { checkProjectManagement } from "./project-checks.js";
import { checkRemoteProjectManagement } from "./remote-project-checks.js";
import type { BrowserWindow } from "electron";

export async function checkToolSearchSetting(
  win: BrowserWindow,
  waitHost: (predicate: string) => Promise<unknown>,
) {
  await checkProjectManagement(win, waitHost);
  await checkRemoteProjectManagement(win, waitHost);
  await win.webContents.executeJavaScript("window.showToolSearchSetting()");
  await waitHost(
    "document.querySelector('[data-testid=settings-tool-search-select]')?.textContent === 'Off'",
  );
  await win.webContents.executeJavaScript(
    "document.querySelector('[data-testid=settings-tool-search-select]').focus()",
  );
  await win.webContents.executeJavaScript(
    "document.querySelector('[data-testid=settings-tool-search-select]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}))",
  );
  await waitHost("document.querySelector('[data-testid=settings-tool-search-option-local]')");
  await win.webContents.executeJavaScript(`(() => {
    const option = document.querySelector('[data-testid=settings-tool-search-option-local]');
    option.dispatchEvent(new PointerEvent('pointermove',{pointerType:'mouse',bubbles:true}));
    option.dispatchEvent(new PointerEvent('pointerup',{pointerType:'mouse',bubbles:true}));
  })()`);
  await waitHost("window.inspectToolSearchSetting() === 'local'");
  assert.equal(
    await win.webContents.executeJavaScript(
      "document.querySelector('[data-testid=settings-tool-search-select]').textContent",
    ),
    "Local",
  );
}
