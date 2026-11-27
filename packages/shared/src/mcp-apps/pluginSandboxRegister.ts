import type { McpAppInstance } from "./instance.js";
import type {
  McpAppCspRelaxations,
  McpAppsResourcePermission,
  McpToolUiCsp,
  PluginSandboxResourceMeta,
} from "./contract.js";

interface PluginSandboxRegisterRequestBase {
  instance: McpAppInstance;
  requestId: string;
  /** 工作区隔离；旧调用允许缺省，新宿主登记须贯穿实际 workspace 范围。 */
  workspacePath?: string;
  workspaceIdentity?: string;
  ownerWebContentsId: number;
  /** `buildPluginSandboxScopeId` 的结果：`tool:<toolCallId>` 或 `surface:<surfaceId>`；扩展视图为 `extension-view:<实例 id>`。 */
  scopeId: string;
  html: string;
  /** 有效 CSP：资源级优先，工具级兜底（host plugin-ui-bridge 已合并）。 */
  csp?: McpToolUiCsp;
  /** 资源级 `_meta["ccbuddy/csp"]` 声明的放宽项。 */
  cspRelaxations?: McpAppCspRelaxations;
  /** 资源声明的浏览器权限；main 据此放宽 Permissions-Policy 与 iframe allow，并把权限请求交给闸门。 */
  permissions?: McpAppsResourcePermission[];
  prefersBorder?: boolean;
  /** 资源级尺寸提示，原样进句柄回给 renderer。 */
  heightHint?: number;
  minFrameHeight?: number;
  /** 资源级强制常驻标记，随句柄 resourceMeta 回 renderer。 */
  showInline?: boolean;
  backgroundRetention?: boolean;
}

/**
 * host → main 登记沙箱内容的消息载荷（模式同 LocalMediaPreviewPathAuthorize*）。
 * 只有扩展视图（docs/plugins/extension-host.md §8）不属于会话：它不填 sessionId，也不伪造会话 id；
 * MCP App 与 Gen UI 仍必须带会话。运行时校验见 validation.ts 的登记 schema 与 Main 注册表。
 */
export type PluginSandboxRegisterRequestPayload = PluginSandboxRegisterRequestBase &
  (
    | {
        contentKind?: undefined;
        sessionId: string;
        pluginId: string;
        /** 资源所属的 MCP server 运行时名；沙箱 partition 按它派生（同一 server 的页面共享一份持久存储）。 */
        serverName: string;
      }
    | {
        /** Gen UI has Host provenance and never impersonates an MCP plugin. */
        contentKind: "gen-ui";
        sessionId: string;
        pluginId?: undefined;
        serverName?: undefined;
      }
    | {
        /** 扩展视图：Window Host 签发凭证，appIdentity 按插件派生；没有会话与 MCP server 名。 */
        contentKind: "extension";
        sessionId?: undefined;
        pluginId: string;
        serverName?: undefined;
      }
  );

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
/** host 内部使用的登记输入：去掉传输层 requestId。 */
export type PluginSandboxRegisterInput = DistributiveOmit<
  PluginSandboxRegisterRequestPayload,
  "requestId"
>;
export interface PluginSandboxHandle {
  instance: McpAppInstance;
  sandboxId: string;
  initId: number;
  shellUrl: string;
  partition: string;
  /** 资源级呈现信息（prefersBorder / heightHint / minFrameHeight / showInline）；资源没声明时省略。 */
  resourceMeta?: PluginSandboxResourceMeta;
}
export type PluginSandboxRegisterResultPayload =
  | ({ requestId: string; ok: true } & PluginSandboxHandle)
  | { requestId: string; ok: false; error: string };
