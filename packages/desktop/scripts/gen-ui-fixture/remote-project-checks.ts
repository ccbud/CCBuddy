import assert from "node:assert/strict";
import type { BrowserWindow } from "electron";

export async function checkRemoteProjectManagement(
  win: BrowserWindow,
  wait: (predicate: string) => Promise<unknown>,
) {
  const execute = (script: string) => win.webContents.executeJavaScript(script);
  await execute("window.showRemoteProjectManager(false)");
  await wait(
    "document.querySelector('[data-testid=project-node]')?.textContent.includes('Remote fixture')",
  );
  assert.equal(await execute("document.querySelectorAll('[data-testid=project-node]').length"), 1);
  await execute("document.querySelector('[data-testid=project-new-task]').click()");
  await wait("window.inspectRemoteProject().bindingCalls === 1");
  assert.equal(await execute("window.inspectRemoteProject().task"), null);
  await execute("window.releaseRemoteBinding()");
  await wait("window.inspectRemoteProject().task !== null");
  const created = await execute("window.inspectRemoteProject()");
  assert.equal(created.task.targetWorkspace.workspacePath, created.directory);
  assert.equal(created.task.targetWorkspace.workspaceIdentity, created.identity);
  assert.equal(created.task.projectId, created.projectId);
  await execute("window.showRemoteProjectManager(true)");
  await wait(
    "document.querySelector('[data-testid=project-node]') && document.querySelector('[data-testid=project-actions]')?.disabled",
  );
  assert.equal(
    await execute("document.querySelector('[data-testid=project-create]')?.disabled"),
    true,
  );
  await execute("document.querySelector('[data-testid=project-new-task]').click()");
  await wait("window.inspectRemoteProject().bindingCalls === 1");
  assert.equal(await execute("window.inspectRemoteProject().task"), null);
  await execute("window.releaseRemoteBinding()");
  await wait("window.inspectRemoteProject().task !== null");
  assert.equal(await execute("window.inspectRemoteProject().task.projectId"), undefined);
}
