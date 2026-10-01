import type {
  OpenPluginUiSideTabRequest,
  PluginUiPresentation,
  PluginUiSidePaneTab,
} from "./contract.js";
import { buildPluginUiSidePaneTabId, readPluginUiScopeRef } from "./contract.js";
import {
  retainPluginUiSessionViewState,
  setPluginUiInstanceDerivation,
} from "./app/pluginUiInstanceStore.js";
import type { PluginUiInstanceDerivation } from "./domain/pluginUiInstancePolicy.js";

/** 时间线 effect 先获得作用域 lease，投影更新独立发布，卸载只释放视图态。 */
export function exampleRetainTimeline(key: string, derivation: PluginUiInstanceDerivation) {
  const release = retainPluginUiSessionViewState(key);
  setPluginUiInstanceDerivation(key, derivation);
  return release;
}

export const examplePresentation: PluginUiPresentation = {
  serverName: "plugin:example-plugin:widget",
  pluginId: "example-plugin@example-marketplace",
  resourceUri: "ui://example-plugin/widget.html",
  preferredDisplayMode: "fullscreen",
  prefersBorder: true,
};

/** 内联卡片 / 面板入口请求打开侧栏时的载荷，以及据此创建的 tab。 */
export function exampleOpenSideTab(request: OpenPluginUiSideTabRequest): PluginUiSidePaneTab {
  const scope = readPluginUiScopeRef(request);
  if (!scope) throw new Error("request needs toolCallId or surfaceId");
  return {
    id: buildPluginUiSidePaneTabId(request),
    type: "plugin-ui",
    parentSessionId: request.parentSessionId,
    ...(request.toolCallId ? { toolCallId: request.toolCallId } : {}),
    ...(request.surfaceId ? { surfaceId: request.surfaceId } : {}),
    ...(request.serverName ? { serverName: request.serverName } : {}),
    pluginId: request.pluginId,
    resourceUri: request.resourceUri,
    title: request.title,
    workspacePath: request.workspacePath,
    workspaceIdentity: request.workspaceIdentity,
    remoteSessionId: request.remoteSessionId ?? null,
  };
}
