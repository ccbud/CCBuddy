import type {
  ModelSelection,
  CCbuddyAgentMcpServer,
  CCbuddyAutomationScheduleRule,
  CCbuddyMcpListMode,
} from "@ccbuddy/shared";
import type { McpAppsAppToolCallResult, McpAppsAppToolDescriptor } from "@ccbuddy/shared/mcp-apps";

export interface CCbuddyAgentWorkspaceTarget {
  workspacePath: string;
  workspaceIdentity?: string;
  /** 远程 workspace 的运行时会话身份；只用于隔离/路由，不能替代 workspacePath。 */
  remoteSessionId?: string;
}

export interface CCbuddyAgentPluginViewParams extends CCbuddyAgentWorkspaceTarget {
  configScope?: "user" | "workspace";
}

export interface CCbuddyAgentListMcpServerStatusesParams extends CCbuddyAgentWorkspaceTarget {
  mcpServers?: CCbuddyAgentMcpServer[];
  mode?: CCbuddyMcpListMode;
}

export interface CCbuddyAgentAddPluginMarketplaceParams extends CCbuddyAgentWorkspaceTarget {
  dryRun?: boolean;
  operationId?: string;
  source: string;
}

export interface CCbuddyAgentRemovePluginMarketplaceParams extends CCbuddyAgentWorkspaceTarget {
  marketplace: string;
}

export interface CCbuddyAgentUpdatePluginMarketplaceParams extends CCbuddyAgentWorkspaceTarget {
  marketplace?: string;
  operationId?: string;
}

export interface CCbuddyAgentInstallPluginParams extends CCbuddyAgentWorkspaceTarget {
  dryRun?: boolean;
  marketplace: string;
  operationId?: string;
  pluginName: string;
  scope?: "user" | "workspace";
}

export interface CCbuddyAgentCancelPluginOperationParams {
  operationId: string;
}

export interface CCbuddyAgentUninstallPluginParams extends CCbuddyAgentWorkspaceTarget {
  marketplace?: string;
  pluginId?: string;
  pluginName?: string;
  removeCache?: boolean;
}

export interface CCbuddyAgentUpdatePluginParams extends CCbuddyAgentWorkspaceTarget {
  pluginId?: string;
  marketplace?: string;
}

export interface CCbuddyAgentRestoreBuiltinPluginParams extends CCbuddyAgentWorkspaceTarget {
  pluginId: string;
}

export interface CCbuddyAgentConfigurePluginParams extends CCbuddyAgentWorkspaceTarget {
  clearOptionKeys?: string[];
  dryRun?: boolean;
  options: Record<string, unknown>;
  pluginId: string;
  scope?: "user" | "workspace";
}

export interface CCbuddyAgentResetPluginConfigParams extends CCbuddyAgentWorkspaceTarget {
  pluginId: string;
  scope?: "user" | "workspace";
}

export interface CCbuddyAgentValidatePluginParams extends CCbuddyAgentWorkspaceTarget {
  marketplace?: string;
  pluginName?: string;
  source?: string;
}

export interface CCbuddyAgentDescribePluginParams extends CCbuddyAgentWorkspaceTarget {
  marketplace: string;
  pluginName: string;
}

export interface CCbuddyAgentSetPluginEnabledParams extends CCbuddyAgentWorkspaceTarget {
  enabled: boolean;
  operationId?: string;
  pluginId: string;
  scope?: "user" | "workspace";
}

// Plugin 对话引用 catalog：
// 带 sessionId → session-owned 冻结 catalog（必须路由到持有该 session 的 workspace client）；
// 不带 → workspace 当前 catalog（新建草稿 Picker）。
export interface CCbuddyAgentPluginReferenceCatalogParams extends CCbuddyAgentWorkspaceTarget {
  sessionId?: string;
}

// Composer Skill catalog：与 Plugin 引用相同，以 sessionId 区分 workspace 当前目录和
// resident Session runtime 快照；不参与 Settings 管理目录。
export interface CCbuddyAgentSkillReferenceCatalogParams extends CCbuddyAgentWorkspaceTarget {
  sessionId?: string;
}

/** 插件 UI：UI 发起的 `ui://` 资源读取。 */
export interface CCbuddyAgentReadMcpResourceParams extends CCbuddyAgentWorkspaceTarget {
  instance: import("@ccbuddy/shared/mcp-apps").McpAppInstance;
  sessionId: string;
  pluginId: string;
  serverName: string;
  uri: string;
}

/** 插件 UI 页面发起的 `resources/read`；参数与 readMcpResource 同形，结果受 8 MiB 与 mimeType 白名单约束。 */
export type CCbuddyAgentReadMcpResourceForUiParams = CCbuddyAgentReadMcpResourceParams;

/** 插件 UI：UI 回调本插件工具；不进审批流，归属由 agent 侧 catalog fail closed。 */
export interface CCbuddyAgentCallMcpToolForUiParams extends CCbuddyAgentWorkspaceTarget {
  instance: import("@ccbuddy/shared/mcp-apps").McpAppInstance;
  sessionId: string;
  pluginId: string;
  serverName: string;
  toolName: string;
  arguments?: Record<string, unknown>;
  /** 宿主生成的调用 id，配合 cancelMcpToolCallForUi。 */
  callId: string;
}
/** 插件 UI 页面发起的 resources/list、resources/templates/list、subscribe、unsubscribe。 */
export interface CCbuddyAgentListMcpResourcesForUiParams extends CCbuddyAgentWorkspaceTarget {
  instance: import("@ccbuddy/shared/mcp-apps").McpAppInstance;
  sessionId: string;
  pluginId: string;
  serverName: string;
  cursor?: string;
}
/** App-Provided Tools：实例身份 = 会话 + 沙箱作用域 + 代际。 */
export interface CCbuddyAgentAppToolInstanceForUiParams extends CCbuddyAgentWorkspaceTarget {
  instance: import("@ccbuddy/shared/mcp-apps").McpAppInstance;
  sessionId: string;
  pluginId: string;
  serverName: string;
  scopeId: string;
  generation: number;
}
export interface CCbuddyAgentRegisterAppToolsForUiParams extends CCbuddyAgentAppToolInstanceForUiParams {
  tools: McpAppsAppToolDescriptor[];
}
export interface CCbuddyAgentAppToolCallForUiParams extends CCbuddyAgentAppToolInstanceForUiParams {
  callId: string;
}
export interface CCbuddyAgentResolveAppToolCallForUiParams extends CCbuddyAgentAppToolCallForUiParams {
  result?: McpAppsAppToolCallResult;
  error?: { message: string };
}
export interface CCbuddyAgentMcpResourceSubscriptionForUiParams extends CCbuddyAgentWorkspaceTarget {
  instance: import("@ccbuddy/shared/mcp-apps").McpAppInstance;
  sessionId: string;
  pluginId: string;
  serverName: string;
  scopeId: string;
  generation: number;
  uri: string;
}
export interface CCbuddyAgentCancelMcpToolCallForUiParams extends CCbuddyAgentWorkspaceTarget {
  instance: import("@ccbuddy/shared/mcp-apps").McpAppInstance;
  sessionId: string;
  pluginId: string;
  serverName: string;
  callId: string;
}
export interface CCbuddyAgentResolveSuggestedPluginReferenceParams extends CCbuddyAgentWorkspaceTarget {
  stableId: string;
  operationId: string;
  clientMode: "desktop-continuous" | "web-remote-replayable";
  deliveryKind: "desktop-continuous" | "web-remote-replayable";
}

// ---- 定时任务(automation)管理参数 ----

export interface CCbuddyAgentCreateAutomationParams extends CCbuddyAgentWorkspaceTarget {
  title: string;
  cronExpr: string;
  relativeDelayMinutes?: number;
  prompt: string;
  modelSelection?: ModelSelection;
  mode?: string;
  recurring?: boolean;
  maxRuns?: number;
  endAt?: number;
  scheduleRule?: CCbuddyAutomationScheduleRule;
}

export interface CCbuddyAgentUpdateAutomationParams extends CCbuddyAgentWorkspaceTarget {
  automationId: string;
  title?: string;
  cronExpr?: string;
  prompt?: string;
  modelSelection?: ModelSelection | null;
  mode?: string | null;
  recurring?: boolean;
  maxRuns?: number | null;
  endAt?: number | null;
  scheduleRule?: CCbuddyAutomationScheduleRule | null;
  scheduleEditedByUser?: boolean;
}

export interface CCbuddyAgentAutomationIdParams extends CCbuddyAgentWorkspaceTarget {
  automationId: string;
}

export interface CCbuddyAgentSetAutomationEnabledParams extends CCbuddyAgentWorkspaceTarget {
  automationId: string;
  enabled: boolean;
}

export interface CCbuddyAgentDeleteAutomationRunParams extends CCbuddyAgentWorkspaceTarget {
  runId: string;
}
