import { app, BrowserWindow } from "electron";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";

export async function writeFailureArtifacts(root: string) {
  const win = BrowserWindow.getAllWindows()[0];
  if (!win) return;
  await writeFile(join(root, "failure.png"), (await win.webContents.capturePage()).toPNG());
  process.stderr.write(
    await win.webContents.executeJavaScript(
      `JSON.stringify({scrollY, anchors:[...document.querySelectorAll('[data-testid="gen-ui-anchor"]')].map(node=>node.getBoundingClientRect().toJSON()), views:[...document.querySelectorAll('webview')].map(node=>({rect:node.getBoundingClientRect().toJSON(),style:node.getAttribute('style')}))})`,
    ),
  );
}

export async function exitWithFailure(root: string, error: unknown): Promise<void> {
  process.stderr.write(error instanceof Error ? (error.stack ?? error.message) : String(error));
  await writeFailureArtifacts(root);
  app.exit(1);
}
