import assert from "node:assert/strict";
import type { BrowserWindow } from "electron";

export async function checkProjectManagement(
  win: BrowserWindow,
  wait: (predicate: string) => Promise<unknown>,
) {
  const execute = (script: string) => win.webContents.executeJavaScript(script);
  await execute("window.showProjectManager()");
  await wait("document.querySelector('[data-testid=project-create]')");
  await execute("document.querySelector('[data-testid=project-create]').click()");
  await wait("document.querySelector('[data-testid=project-editor]')");
  const directories = await execute("window.harness.projectDirectories()");
  await execute(`(() => {
    const change = (selector, value) => {
      const input = document.querySelector(selector);
      Object.getOwnPropertyDescriptor(input.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value').set.call(input, value);
      input.dispatchEvent(new Event('input', {bubbles:true}));
      input.dispatchEvent(new Event('change', {bubbles:true}));
    };
    change('[data-testid=project-name]', 'Workspace project');
    change('[data-testid=project-roots]', ${JSON.stringify(directories.join("\n"))});
  })()`);
  await execute("document.querySelector('[data-testid=project-save]').click()");
  await wait(
    "document.querySelector('[data-testid=project-node]') && !document.querySelector('[data-testid=project-editor]')",
  );
  const id = await execute(
    "document.querySelector('[data-testid=project-node]').dataset.projectId",
  );
  await execute("document.querySelector('[data-testid=project-new-task]').click()");
  await wait("window.inspectProjectTask() !== null");
  assert.deepEqual(await execute("window.inspectProjectTask()"), {
    projectId: id,
    targetWorkspace: {
      projectId: id,
      workspacePath: directories[0],
      additionalDirectories: [directories[1]],
    },
  });
  await execute(
    "document.querySelector('[data-testid=project-actions]').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))",
  );
  await wait("document.querySelector('[role=menuitem]')");
  await execute(
    "[...document.querySelectorAll('[role=menuitem]')].find(item => item.textContent.includes('Remove project')).click()",
  );
  await wait("document.querySelectorAll('[data-testid=project-node]').length === 0");
  await execute("document.querySelector('[aria-label=\"Removed projects\"]').click()");
  await wait("document.querySelector('[data-testid=project-actions]')");
  await execute(
    "document.querySelector('[data-testid=project-actions]').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))",
  );
  await wait("document.querySelector('[data-testid=project-purge]')");
  await execute(
    "[...document.querySelectorAll('[role=menuitem]')].find(item => item.textContent.includes('Restore project')).click()",
  );
  await wait("document.querySelectorAll('[data-testid=project-node]').length === 0");
  await execute("document.querySelector('[aria-label=\"Removed projects\"]').click()");
  await wait("document.querySelector('[data-testid=project-node]')");
  assert.equal(
    await execute("document.querySelector('[data-testid=project-node]').dataset.projectId"),
    id,
  );
  await execute(
    "document.querySelector('[data-testid=project-actions]').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))",
  );
  await wait("document.querySelector('[role=menuitem]')");
  await execute(
    "[...document.querySelectorAll('[role=menuitem]')].find(item => item.textContent.includes('Remove project')).click()",
  );
  await wait("document.querySelectorAll('[data-testid=project-node]').length === 0");
  await execute("document.querySelector('[aria-label=\"Removed projects\"]').click()");
  await wait("document.querySelector('[data-testid=project-actions]')");
  const requestPurge = async () => {
    await execute(
      "document.querySelector('[data-testid=project-actions]').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))",
    );
    await wait("document.querySelector('[data-testid=project-purge]')");
    await execute("document.querySelector('[data-testid=project-purge]').click()");
    await wait("document.querySelector('[data-testid=project-purge-confirm]')");
  };
  await requestPurge();
  await execute(
    "[...document.querySelectorAll('[data-testid=project-purge-confirm] button')].find(item => item.textContent.includes('Cancel')).click()",
  );
  await wait("!document.querySelector('[data-testid=project-purge-confirm]')");
  assert.equal(
    await execute("document.querySelector('[data-testid=project-node]').dataset.projectId"),
    id,
  );
  await requestPurge();
  await execute(
    "[...document.querySelectorAll('[data-testid=project-purge-confirm] button')].find(item => item.textContent.includes('Permanently delete')).click()",
  );
  await wait(
    "document.querySelectorAll('[data-testid=project-node]').length === 0 && document.querySelector('[role=status]')",
  );
  assert.match(await execute("document.querySelector('[role=status]').textContent"), /0 failures/);
}
