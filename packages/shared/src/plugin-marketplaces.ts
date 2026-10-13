export interface DefaultPluginMarketplace {
  id: string;
  source: string;
  name: string;
  description: string;
  pluginCount: number;
  lastUpdated?: string;
}

export const CCBUDDY_OFFICIAL_PLUGIN_MARKETPLACE_ID = "ccbuddy-plugins-official";

/**
 * Claude Code 官方市场（GitHub git 源）。它不是 CCbuddy 的强依赖：GitHub 不可达时刷新必然失败，
 * 该失败不应作为错误提示打扰用户，UI 侧按此 id 静默处理其刷新失败（任何原因）。
 */
export const CLAUDE_OFFICIAL_PLUGIN_MARKETPLACE_ID = "claude-plugins-official";

/** Settings 三类资源发现共用；Bootstrap 单测与官方 definition 的 defaultEnabled 机械对照。 */
// 内置默认启用集合与 CLI/SEA 实际随包发布清单一致，不为已移除的上游插件声明默认状态。
export const DEFAULT_ENABLED_OFFICIAL_PLUGIN_IDS: ReadonlySet<string> = new Set([
  "browser-use@ccbuddy-plugins-official",
  // node_repl 宿主无商店 listing，默认启用保证 Browser Use 有可执行宿主。
  "node-repl-host@ccbuddy-plugins-official",
  "visualize@ccbuddy-plugins-official",
]);

export const DEFAULT_PLUGIN_MARKETPLACES: DefaultPluginMarketplace[] = [
  {
    // 内置插件由应用包本地 seed。此 source 仅用于建立本地 known record，
    // adapter 会将它解析为本机 marketplace.json，绝不触发官方 CDN 请求。
    id: CCBUDDY_OFFICIAL_PLUGIN_MARKETPLACE_ID,
    source: "bundled:ccbuddy",
    name: "CCbuddy built-in plugins",
    description: "Plugins bundled with CCbuddy.",
    pluginCount: 0,
  },
  {
    id: CLAUDE_OFFICIAL_PLUGIN_MARKETPLACE_ID,
    source: "anthropics/claude-plugins-official",
    name: CLAUDE_OFFICIAL_PLUGIN_MARKETPLACE_ID,
    description:
      "Directory of popular Claude Code extensions including development tools, productivity plugins, and MCP integrations",
    // 只内置官方 catalog 来源，不把远端 manifest 快照打包进仓库；首次刷新前数量未知。
    pluginCount: 0,
  },
];

// 商店「公开」分段只有一个 CCbuddy 官方市场 id，内置与 CDN 不再拆分身份。
export const PUBLIC_STORE_MARKETPLACE_IDS = [CCBUDDY_OFFICIAL_PLUGIN_MARKETPLACE_ID] as const;

export function isPublicStoreMarketplaceId(id: string): boolean {
  return (PUBLIC_STORE_MARKETPLACE_IDS as readonly string[]).includes(id);
}
