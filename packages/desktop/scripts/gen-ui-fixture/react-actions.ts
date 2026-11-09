import type { BrowserWindow } from "electron";

export function createReactFixtureActions(win: BrowserWindow) {
  const waitHost = async (predicate: string) =>
    win.webContents.executeJavaScript(
      `new Promise((resolve,reject)=>{const end=Date.now()+8000;const tick=()=>{if(${predicate})resolve(true);else if(Date.now()>end)reject(new Error(${JSON.stringify(`React fixture condition timed out: ${predicate}`)}));else requestAnimationFrame(tick)};tick()})`,
    );
  const clickHost = async (text: string) =>
    win.webContents.executeJavaScript(
      `(() => { const button = [...document.querySelectorAll('button')].find(node => (node.textContent === ${JSON.stringify(text)} || node.getAttribute("aria-label") === ${JSON.stringify(text)})); if(!button) throw new Error('button not found'); button.click(); })()`,
    );
  return { waitHost, clickHost };
}
