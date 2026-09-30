// `plugins/listUiSurfaces`：工作区级只读投影，
// 返回已启用插件清单 `ui.surfaces[]` 的合法条目。与 plugin-reference-catalog.ts 同因分文件：plugins.ts 已近门禁。
import {
  ccbuddyPluginsListUiSurfacesParamsSchema,
  type CCbuddyPluginUiSurface,
  type CCbuddyPluginsListUiSurfacesResult,
} from "@ccbuddy/shared";
import type { PluginMetadata } from "@ccbuddy/contracts";
import { resolveCCbuddyPlugins } from "../plugins.js";
import { parseParams, type CCbuddyProtocolAgentServerContext } from "./server-types.js";

export function listPluginUiSurfacesFromPlugins(
  plugins: readonly PluginMetadata[],
): CCbuddyPluginUiSurface[] {
  const surfaces: CCbuddyPluginUiSurface[] = [];
  for (const plugin of plugins) {
    // 禁用插件没有运行时 MCP，入口不可用；解析仍保留在 metadata 里供管理页展示。
    if (!plugin.enabled) continue;
    for (const surface of plugin.uiSurfaces ?? []) {
      surfaces.push({
        pluginId: plugin.id,
        pluginName: plugin.name,
        id: surface.id,
        title: surface.title,
        ...(surface.icon ? { icon: surface.icon } : {}),
        server: surface.server,
        resourceUri: surface.resourceUri,
        availability: surface.availability,
      });
    }
  }
  return surfaces;
}

export async function listPluginUiSurfaces(
  context: CCbuddyProtocolAgentServerContext,
  rawParams: unknown,
): Promise<CCbuddyPluginsListUiSurfacesResult> {
  const params = parseParams(ccbuddyPluginsListUiSurfacesParamsSchema, rawParams);
  const outcome = resolveCCbuddyPlugins({
    logger: context.logger,
    workingDirectory: params.workspace.workspacePath,
  });
  return { surfaces: listPluginUiSurfacesFromPlugins(outcome.plugins) };
}
