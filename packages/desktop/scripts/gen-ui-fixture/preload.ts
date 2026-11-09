import { contextBridge, ipcRenderer } from "electron";
import { PlatformChannels } from "@ccbuddy/shared";
import { installPluginSandboxHostBridge } from "../../src/preload/pluginSandbox/hostBridge.js";
installPluginSandboxHostBridge();
contextBridge.exposeInMainWorld("harness", {
  config: () => ipcRenderer.invoke("fixture-config"),
  project: (method: string, input: unknown) => ipcRenderer.invoke("fixture-project", method, input),
  projectDirectories: () => ipcRenderer.invoke("fixture-project-directories"),
  remoteProject: (method: string, input: unknown, legacy: boolean) =>
    ipcRenderer.invoke("fixture-remote-project", method, input, legacy),
  bridge: (method: string, input: unknown) => ipcRenderer.invoke("fixture-service", method, input),
  owner: () => ipcRenderer.invoke(PlatformChannels.PluginSandboxOwnerWebContentsId),
  dispose: (id: string, init: number) =>
    ipcRenderer.invoke(PlatformChannels.PluginSandboxDispose, id, init),
  gesture: () => ipcRenderer.invoke("fixture-gesture"),
});
ipcRenderer.on("fixture-state", (_, payload) =>
  window.postMessage({ type: "fixture-notification", payload }, "*"),
);
