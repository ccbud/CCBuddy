import {
  databaseStartupErrorCodeSchema,
  databaseStartupErrorDetailsSchema,
  databaseMigrationFactsSchema,
} from "../database-startup.js";
/* oxlint-disable eslint(max-lines) -- CCbuddy Protocol schema 需要单文件导出，方便 app 与 agent 共享同一份协议契约。 */
// ── 旧协议删除边界──────────────────────
// 剩余 ~257 个导出：旧 CCbuddy Protocol 方法契约、请求/响应/事件 schema、
// session/workspace state snapshot 投影等（承重类型已迁 ccbuddy-protocol-legacy-types.ts）。
// 已连根删除的死词（词表+schema+两侧实现）：session/steer、session/rewind、
// session/rewindCascade、session/previewFileRewind、session/applyFileRewind、
// prompt/enhance 全簇（含 promptEnhanceResult 通知）、plugins/marketplace/list；
// session/fork 客户端链已删（op+schema 留存 = v4 forkSessionAtMessage 钩子消费）。
// 消费者：services 旧栈（ccbuddyProtocolClient/ccbuddyAgent/ccbuddyAgentService/ccbuddySession*）、
// CLI bootstrap 旧协议 server（ccbuddy-protocol/server-operations、plugins、session-mapper 等）、
// UI 旧投影（ccbuddySessionProjection 等读路径）。
// 上述旧协议 client/server 组删除时，本文件整体删除。
// 注：外部零消费 schema 多为存活 schema 联合的内部依赖，随宿主文件一起处理，勿单删。
import { bashOutputDisplaySchema } from "../bash-output-display.js";
// 后台详情共享精简的只读响应 schema，不携带命令或计时元数据。
export * from "../background-bash-output.js";
import { executionOutputPreviewSchema } from "../execution-output-preview.js";
import { z } from "zod";
export * from "../process-diagnostic.js";
import { errorAttributionSchema } from "../ccbuddy-protocol-v4/snapshot.js";
import { modelSelectionSchema } from "../model-selection.js";
import { completeModelPropertiesDataSchema } from "../model-config.js";
import { accountProviderUnavailableReasonSchema } from "../account-provider-state.js";
import { modelExecutionSchema } from "../model-execution.js";
import { APP_USAGE_RANGES, appUsageSnapshotSchema } from "../usage-stats.js";
import { ccbuddyAutomationBotDeliveryTargetSchema } from "../bots.js";
// browser-use 命令/结果契约单一来源：agent 构造、协议校验和 main executor 共用同一 schema。
import { browserClientModeSchema, browserCommandSchema } from "../browser-use/commands.js";
import {
  browserBackendListResultSchema,
  browserSessionContextKindSchema,
} from "../browser-use/backend.js";
import { browserCommandResultSchema } from "../browser-use/result.js";
import { integratedTerminalShellSelectionSchema } from "../validationAppSettings.js";
import { ccbuddyTaskModeSchema } from "../ccbuddy-task-mode-schema.js";
import { OFFICIAL_MCP_AUTH_PORT_FAILURE_REASONS } from "../official-mcp-auth.js";
import {
  ccbuddyDeliveryKindSchema,
  ccbuddyMessageVisibilitySchema,
  ccbuddySyntheticUserMessageSourceSchema as legacyCCbuddySyntheticUserMessageSourceSchema,
  ccbuddyWorkspaceRefSchema,
  ccbuddyPermissionDecisionSchema,
  ccbuddyPermissionResponseSchema,
  ccbuddyPermissionUpdateSchema,
  ccbuddySessionModeSchema,
  ccbuddySessionStatusSchema,
  ccbuddySessionKindSchema,
  ccbuddySessionGoalSchema,
  ccbuddySessionGoalVerificationSchema,
  ccbuddySessionGoalVerificationTimelineSchema,
  ccbuddyInteractionRequestOriginSchema,
  ccbuddyToolStateSchema,
  ccbuddySessionApiRetryStatusSchema,
  ccbuddySessionContextUsageSchema,
  ccbuddySessionInfoSchema,
  ccbuddySessionRuntimeStateSchema,
  ccbuddyMessageWithPartsSchema,
  ccbuddyMessagePartSchema,
} from "../ccbuddy-protocol-legacy-types.js";

export {
  hookExecutionProjectionSchema,
  hookInvocationRowSchema,
  type HookExecutionProjection,
  type HookInvocationRow,
} from "../ccbuddy-protocol-v4/rows.js";

export const CCBUDDY_PROTOCOL_NAME = "CCbuddy Protocol" as const;
export const CCBUDDY_PROTOCOL_VERSION = 1 as const;
// V4 wire 与 legacy 主协议并存；禁止为了 V4 physical framing 改写 legacy 版本。
export const CCBUDDY_PROTOCOL_V4_WIRE_VERSION = 3 as const;
export const ccbuddyRuntimeCapabilitiesSchema = z.object({
  independentPlanState: z.boolean().optional(),
});
export const ccbuddyProtocolErrorCodes = {
  sessionUnavailable: -32004,
} as const;

const nonEmptyString = z.string().trim().min(1);
const jsonObjectSchema = z.record(z.string(), z.unknown());
const timestampMsSchema = z.number().int().nonnegative();
const protocolInstantSchema = z.union([timestampMsSchema, nonEmptyString, z.date()]);

// Tool result display 不受模型文本 budget 约束；Node REPL 图片必须在 Agent/App 协议边界
// 做严格限长，避免截图把 continuous 或 replayable 消息扩成无界载荷。
export const ccbuddyNodeReplImageToolResultDisplaySchema = z
  .object({
    kind: z.literal("node_repl_images"),
    images: z
      .array(
        z
          .object({
            base64: z
              .string()
              .min(1)
              .max(200 * 1024),
            mimeType: z.string().regex(/^image\/[a-z0-9.+-]+$/iu),
          })
          .strict(),
      )
      .min(1)
      .max(2),
    truncated: z.boolean().optional(),
    source: z.literal("browser_turn_end").optional(),
  })
  .strict();

// 同理：CreateWorkflow 的类型检查诊断也是 display 通道，必须在协议边界限长，
// 避免大量诊断把 continuous/replayable 消息扩成无界载荷。
// causalityGraph 在工具输出边界已限长，这里镜像同一组上界（与 v4 rows 保持一致）。
// 图的词汇表刻意很小：step 卡片 + actor 车道 + 一种箭头（runs after，`back` 只标回边）+
// 返回物标记。分析器的 kind / certainty / exact / region 不进载荷。
// 名字只在运行时成形（`` agent(`研究员${i + 1}`) ``）时静态能拿到的形状：第一个洞之前的
// 字面量（head）与最后一个洞之后的字面量（tail）。至少一个在场，两者都已 trim 且含实义字符。
// Bug 修复：这两个字段随 0a8b059f40 落进 contracts 与 v4 镜像，v3 这份漏改——.strict()
// 之下带插值名的工作流会让整个 display 验证失败、图整块消失，所以这里必须与 v4 逐字段对齐。
const ccbuddyWorkflowNamePatternSchema = z
  .object({
    head: z.string().min(1).max(128).optional(),
    tail: z.string().min(1).max(128).optional(),
  })
  .strict();

// 一条边 = runs after；step 边与阶段边同形，`back` 只标循环回边。
const ccbuddyWorkflowEdgeSchema = z
  .object({
    from: z.string().min(1).max(64),
    to: z.string().min(1).max(64),
    back: z.literal(true).optional(),
  })
  .strict();

const ccbuddyCreateWorkflowCausalityGraphDisplaySchema = z
  .object({
    steps: z
      .array(
        z
          .object({
            id: z.string().min(1).max(64),
            kind: z.enum(["ask", "world-read"]),
            label: z.string().min(1).max(128),
            // 内联 `agent()` receiver 让 label 落到兜底串时，那个名字的静态形状。
            labelPattern: ccbuddyWorkflowNamePatternSchema.optional(),
            line: z.number().int().positive().optional(),
            column: z.number().int().positive().optional(),
            lane: z.string().min(1).max(64),
            lanes: z.array(z.string().min(1).max(64)).max(32).optional(),
            // 展开自的站点 id，只出现在 may-set 车道展开的拷贝上（实时叠加的关联键）；
            // 加字段是 additive 的，不带它的旧载荷照常通过 .strict()。
            source: z.string().min(1).max(64).optional(),
            // 作者用 `phase("…")` 标记划入的阶段。
            // 与图的 phases / phaseEdges / exits 同进同退：全在场或全缺席。
            phase: z.string().min(1).max(64).optional(),
            repeat: z.enum(["stack", "serial"]).optional(),
          })
          .strict(),
      )
      .max(64),
    lanes: z
      .array(
        z
          .object({
            id: z.string().min(1).max(64),
            name: z.string().min(1).max(128).optional(),
            // `name` 缺席而 agent() 首参是带洞的模板串时的静态形状；与 name 互斥。
            namePattern: ccbuddyWorkflowNamePatternSchema.optional(),
            line: z.number().int().positive().optional(),
            column: z.number().int().positive().optional(),
          })
          .strict(),
      )
      .max(32),
    // 参与者与交接；镜像 v4。
    participants: z
      .array(
        z
          .object({
            id: z.string().min(1).max(64),
            phase: z.string().min(1).max(64),
            lane: z.string().min(1).max(64),
            steps: z.array(z.string().min(1).max(64)).min(1).max(64),
            member: z
              .object({ index: z.number().int().nonnegative(), of: z.number().int().positive() })
              .strict()
              .optional(),
            many: z.literal(true).optional(),
          })
          .strict(),
      )
      .max(64),
    handoffs: z
      .array(
        ccbuddyWorkflowEdgeSchema
          .extend({ types: z.array(z.string().min(1).max(128)).min(1).max(8).optional() })
          .strict(),
      )
      .max(256),
    // 阶段词汇表：作者施加的分组结构，主画面以它为节点。与 phaseEdges / exits / Step.phase
    // 全有或全无——零标记脚本全缺席，UI 据此退回 step/车道视图。零成员阶段也在表里。
    // `unphased` 无 name，显示名由 UI 本地化。
    phases: z
      .array(
        z
          .object({
            id: z.string().min(1).max(64),
            name: z.string().min(1).max(128).optional(),
            line: z.number().int().positive().optional(),
            column: z.number().int().positive().optional(),
            // 进入本阶段时还在跑的其他阶段（它们的 strand 尚未 join），阶段表序，不含自己，
            // 为空时缺席。是节点事实而不是边——控制没有从那里转移过来，所以不进 phaseEdges。
            // 时间轴据此把相邻阶段折成一条分叉的「带」，侧栏迷你轨道画成双线段。
            alongside: z.array(z.string().min(1).max(64)).min(1).max(32).optional(),
          })
          .strict(),
      )
      .max(32)
      .optional(),
    phaseEdges: z.array(ccbuddyWorkflowEdgeSchema).max(128).optional(),
    // 控制流可在其后正常完成的阶段（阶段视图的「阶段 → 返回物」箭头）；组内可为空数组。
    exits: z.array(z.string().min(1).max(64)).max(32).optional(),
    sink: z.array(z.string().min(1).max(64)).max(64).optional(),
    truncated: z.boolean().optional(),
  })
  .strict();

export const ccbuddyCreateWorkflowToolResultDisplaySchema = z
  .object({
    kind: z.literal("create_workflow"),
    ok: z.boolean(),
    errorCount: z.number().int().nonnegative(),
    diagnostics: z
      .array(
        z
          .object({
            line: z.number().int().nonnegative(),
            column: z.number().int().nonnegative(),
            code: z.number().int().nonnegative(),
            message: z.string().min(1).max(2_048),
          })
          .strict(),
      )
      .max(100),
    causalityGraph: ccbuddyCreateWorkflowCausalityGraphDisplaySchema.optional(),
    truncated: z.boolean().optional(),
  })
  .strict();

const ccbuddyToolResultObjectSchema = jsonObjectSchema.superRefine((result, context) => {
  const display = result.display;
  if (typeof display !== "object" || display === null || Array.isArray(display)) {
    return;
  }
  const kind = (display as Record<string, unknown>).kind;
  const schemaByKind: Record<string, z.ZodTypeAny> = {
    node_repl_images: ccbuddyNodeReplImageToolResultDisplaySchema,
    create_workflow: ccbuddyCreateWorkflowToolResultDisplaySchema,
    bash_output: bashOutputDisplaySchema,
  };
  const schema = typeof kind === "string" ? schemaByKind[kind] : undefined;
  if (!schema) return;
  const parsed = schema.safeParse(display);
  if (parsed.success) return;
  for (const issue of parsed.error.issues) {
    context.addIssue({ ...issue, path: ["display", ...issue.path] });
  }
});

export const ccbuddyProtocolRequestIdSchema = z.union([z.string(), z.number().int()]);
export type CCbuddyProtocolRequestId = z.infer<typeof ccbuddyProtocolRequestIdSchema>;

export const ccbuddyProtocolTraceSchema = z
  .object({
    traceparent: nonEmptyString.optional(),
    traceId: nonEmptyString.optional(),
    parentId: nonEmptyString.optional(),
    spanId: nonEmptyString.optional(),
  })
  .strict();
export type CCbuddyProtocolTrace = z.infer<typeof ccbuddyProtocolTraceSchema>;

export const ccbuddyProtocolRequestSchema = z
  .object({
    id: ccbuddyProtocolRequestIdSchema,
    method: nonEmptyString,
    params: z.unknown().optional(),
    trace: ccbuddyProtocolTraceSchema.optional(),
  })
  .strict();
export type CCbuddyProtocolRequest = z.infer<typeof ccbuddyProtocolRequestSchema>;

export const ccbuddyProtocolNotificationSchema = z
  .object({
    method: nonEmptyString,
    params: z.unknown().optional(),
    trace: ccbuddyProtocolTraceSchema.optional(),
  })
  .strict();
export type CCbuddyProtocolNotification = z.infer<typeof ccbuddyProtocolNotificationSchema>;

export const ccbuddyProtocolResponseSchema = z
  .object({
    id: ccbuddyProtocolRequestIdSchema,
    result: z.unknown(),
  })
  .strict();
export type CCbuddyProtocolResponse = z.infer<typeof ccbuddyProtocolResponseSchema>;

export const ccbuddyProtocolErrorSchema = z
  .object({
    id: ccbuddyProtocolRequestIdSchema,
    error: z
      .object({
        code: z.number().int(),
        message: nonEmptyString,
        data: z.unknown().optional(),
      })
      .strict(),
  })
  .strict();
export type CCbuddyProtocolError = z.infer<typeof ccbuddyProtocolErrorSchema>;

export const ccbuddyProtocolMessageSchema = z.union([
  ccbuddyProtocolRequestSchema,
  ccbuddyProtocolNotificationSchema,
  ccbuddyProtocolResponseSchema,
  ccbuddyProtocolErrorSchema,
]);
export type CCbuddyProtocolMessage = z.infer<typeof ccbuddyProtocolMessageSchema>;

export const ccbuddyProtocolNotifications = {
  storageStartup: "startup/storageState",
  providerRuntimeHeadersCancelled: "interaction/providerRuntimeHeadersCancelled",
  mcpTelemetry: "process/mcpTelemetry",
  mcpResourceSamples: "process/mcpResourceSamples",
  toolExecResource: "process/toolExecResource",
  pluginOperationProgress: "plugins/operationProgress",
  processResourceSample: "process/resourceSample",
} as const;

/** 启动控制面独立于 task stream；数据库身份不可携带路径/凭据。 */
export const ccbuddyStorageStartupStateSchema = z
  .object({
    schemaVersion: z.literal(1),
    attemptId: z.string().min(1).max(128),
    sequence: z.number().int().positive(),
    databaseId: z.string().min(1).max(128),
    databaseKind: z.enum(["session", "tasks-index"]),
    phase: z.enum(["checking", "waiting_for_lock", "migrating", "committing", "ready", "failed"]),
    // 包含锁内、版本 SQL 之前的可选 lastAppliedMigrationId；旧通知仍可解析。
    migration: databaseMigrationFactsSchema.optional(),
    elapsedMs: z.number().nonnegative().finite(),
    completed: z.number().int().nonnegative().optional(),
    total: z.number().int().nonnegative().optional(),
    errorCode: databaseStartupErrorCodeSchema.optional(),
    ...databaseStartupErrorDetailsSchema.shape,
  })
  .strict()
  .superRefine((state, context) => {
    if (state.phase === "failed" && !state.errorCode)
      context.addIssue({ code: "custom", message: "failed requires errorCode" });
  });
export type CCbuddyStorageStartupState = z.infer<typeof ccbuddyStorageStartupStateSchema>;

const ccbuddyMcpTelemetryPlatformSchema = z.enum([
  "aix",
  "android",
  "darwin",
  "freebsd",
  "haiku",
  "linux",
  "netbsd",
  "openbsd",
  "sunos",
  "win32",
  "cygwin",
]);
const ccbuddyMcpTelemetryArchSchema = z.enum([
  "arm",
  "arm64",
  "ia32",
  "loong64",
  "mips",
  "mipsel",
  "ppc",
  "ppc64",
  "riscv64",
  "s390",
  "s390x",
  "x64",
]);
const ccbuddyMcpTelemetryBaseSchema = z
  .object({
    arch: ccbuddyMcpTelemetryArchSchema,
    occurredAt: z.number().int().nonnegative(),
    platform: ccbuddyMcpTelemetryPlatformSchema,
  })
  .strict();
const ccbuddyMcpProcessTelemetryBaseShape = {
  mcpId: z
    .string()
    .regex(
      /^(?:builtin:(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+(?::(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+)*|(?:plugin|custom):[a-f0-9]{12})$/,
    ),
  mcpInstanceId: nonEmptyString,
  mcpIsolation: z.enum(["session", "workspace"]),
  mcpSource: z.enum(["builtin", "plugin", "custom"]),
} as const;

export const ccbuddyMcpTelemetryEventSchema = z.discriminatedUnion("kind", [
  ccbuddyMcpTelemetryBaseSchema
    .extend({
      kind: z.literal("process_start"),
      ...ccbuddyMcpProcessTelemetryBaseShape,
    })
    .strict(),
  ccbuddyMcpTelemetryBaseSchema
    .extend({
      kind: z.literal("process_crash"),
      ...ccbuddyMcpProcessTelemetryBaseShape,
      affectedSessionCount: z.number().int().nonnegative().max(10_000),
      exitCode: z.number().int().nullable(),
      signal: nonEmptyString.nullable(),
      uptimeMs: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    })
    .strict(),
  ccbuddyMcpTelemetryBaseSchema
    .extend({
      kind: z.literal("session_startup"),
      configuredCount: z.number().int().nonnegative().max(10_000),
      connectedCount: z.number().int().nonnegative().max(10_000),
      failedCount: z.number().int().nonnegative().max(10_000),
      processCount: z.number().int().nonnegative().max(10_000),
      sessionId: nonEmptyString,
    })
    .strict(),
  ccbuddyMcpTelemetryBaseSchema
    .extend({
      kind: z.literal("memory"),
      ...ccbuddyMcpProcessTelemetryBaseShape,
      memoryKb: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
      memoryScope: z.enum(["process_tree", "direct_process"]),
      orphanSuspected: z.boolean(),
      ownerSessionCount: z.number().int().nonnegative().max(10_000),
      unownedSeconds: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    })
    .strict(),
]);
export type CCbuddyMcpTelemetryEvent = z.infer<typeof ccbuddyMcpTelemetryEventSchema>;

/** MCP 每五分钟只探测一次，周期由生产者与设备总量过期判据共用。 */
export const CCBUDDY_MCP_RESOURCE_SAMPLE_INTERVAL_MS = 5 * 60_000;

export const ccbuddyMcpResourceSampleSchema = z
  .object({
    mcpId: ccbuddyMcpProcessTelemetryBaseShape.mcpId,
    instanceToken: z.string().regex(/^[A-Za-z0-9_-]{8,64}$/),
    sampledAt: z.number().int().nonnegative(),
    intervalMs: z.number().finite().positive(),
    processCount: z.number().int().positive().max(100_000),
    rssKbTotal: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    rssKbMaxProcess: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    cpuTimeMsDelta: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    uptimeMinutes: z.number().int().nonnegative(),
    platform: ccbuddyMcpTelemetryPlatformSchema,
    arch: ccbuddyMcpTelemetryArchSchema,
    logicalCpuCount: z.number().int().positive().max(4_096),
    totalMemoryGb: z.number().int().nonnegative().max(1_048_576),
  })
  .strict();
export type CCbuddyMcpResourceSample = z.infer<typeof ccbuddyMcpResourceSampleSchema>;
// 通知输入有界；main 另按每个上报窗口的 32 个 MCP 分组执行事件额度。
export const ccbuddyMcpResourceSamplesSchema = z.array(ccbuddyMcpResourceSampleSchema).max(1_024);

export const BASH_RESOURCE_SAMPLE_INTERVAL_MS = 15_000;
export const BASH_RESOURCE_MAX_SAMPLES = 20;

/** Bash 子进程的有界完成事实；禁止命令、路径与会话标识进入遥测旁路。 */
export const ccbuddyToolExecResourceSchema = z
  .object({
    // 同一完成事实可能经多个 Host 转发；随机标识仅供 main 去重，旧 CLI 缺字段仍兼容。
    completionToken: z.string().uuid().optional(),
    platform: ccbuddyMcpTelemetryPlatformSchema,
    toolName: z.literal("bash"),
    durationMs: z.number().finite().min(BASH_RESOURCE_SAMPLE_INTERVAL_MS),
    exitKind: z.enum(["completed", "timeout", "killed", "error"]),
    treeRssKbPeak: z.number().finite().nonnegative().optional(),
    treeCpuTimeMs: z.number().finite().nonnegative().optional(),
    sampleCount: z.number().int().nonnegative().max(BASH_RESOURCE_MAX_SAMPLES),
    cliRssKb: z.number().finite().nonnegative(),
    systemFreeMemoryKb: z.number().finite().nonnegative(),
  })
  .strict();
export type CCbuddyToolExecResource = z.infer<typeof ccbuddyToolExecResourceSchema>;

export const ccbuddyProcessResourceSampleSchema = z
  .object({
    platform: z.enum([
      "aix",
      "android",
      "darwin",
      "freebsd",
      "haiku",
      "linux",
      "netbsd",
      "openbsd",
      "sunos",
      "win32",
      "cygwin",
    ]),
    arch: z.enum([
      "arm",
      "arm64",
      "ia32",
      "loong64",
      "mips",
      "mipsel",
      "ppc",
      "ppc64",
      "riscv64",
      "s390",
      "s390x",
      "x64",
    ]),
    logicalCpuCount: z.number().int().positive().max(4_096),
    intervalMs: z
      .number()
      .int()
      .positive()
      .max(7 * 24 * 60 * 60 * 1_000),
    cpuCores: z.number().finite().nonnegative().max(4_096),
    cpuPercent: z.number().finite().nonnegative().max(100_000),
    rssKb: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    /**
     * 以下四项为遥测新增字段，全部可选：旧 CLI 发来的样本仍能通过校验，因此
     * **不递增协议握手版本号**（握手版本是兼容性开关，不是字段版本）。
     */
    heapUsedKb: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),
    uptimeMinutes: z
      .number()
      .int()
      .nonnegative()
      .max(10 * 365 * 24 * 60)
      .optional(),
    totalMemoryGb: z.number().int().nonnegative().max(1_048_576).optional(),
    /**
     * CLI 进程启动时随机生成的实例标识，仅供 app 侧 main 统计「同时存活几个 CLI 进程」
     * 与「最大单进程 RSS」。不进 ARMS 属性、不含 pid。收紧字符集是隐私红线的机械保障：
     * 路径、workspace 标识这类内容不可能通过校验。
     */
    instanceToken: z
      .string()
      .regex(/^[A-Za-z0-9_-]{8,64}$/)
      .optional(),
  })
  .strict();
export type CCbuddyProcessResourceSample = z.infer<typeof ccbuddyProcessResourceSampleSchema>;

export const ccbuddyProcessChildProcessesParamsSchema = z.object({}).strict();
export const ccbuddyProcessChildProcessSchema = z
  .object({
    pid: z.number().int().positive(),
    serverName: nonEmptyString,
    mcpSource: z.enum(["builtin", "plugin", "custom"]),
    /** 官方/第三方插件的插件名（`plugin:<name>:<key>` 的 name，或官方 host MCP 对应插件）；custom 无 */
    pluginName: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddyProcessChildProcessesResultSchema = z
  .object({
    processes: z.array(ccbuddyProcessChildProcessSchema).max(10_000),
  })
  .strict();
export type CCbuddyProcessChildProcess = z.infer<typeof ccbuddyProcessChildProcessSchema>;
export type CCbuddyProcessChildProcessesResult = z.infer<
  typeof ccbuddyProcessChildProcessesResultSchema
>;

export type CCbuddyDeliveryKind = z.infer<typeof ccbuddyDeliveryKindSchema>;
// TurnStarted 与持久 message 必须共用同一来源词表；否则 live event 能通过而 cold
// message 在 app/agent 边界被拒绝，造成 continuous/replayable 语义分叉。
const ccbuddyTurnInputSourceSchema = legacyCCbuddySyntheticUserMessageSourceSchema;
export const ccbuddySessionPersistenceSchema = z.enum(["immediate", "deferred"]);
export type CCbuddySessionPersistence = z.infer<typeof ccbuddySessionPersistenceSchema>;
export type CCbuddyWorkspaceRef = z.infer<typeof ccbuddyWorkspaceRefSchema>;
export const ccbuddyPermissionOptionSchema = z
  .object({
    optionId: nonEmptyString,
    kind: nonEmptyString,
    name: nonEmptyString,
    description: z.string().optional(),
    response: ccbuddyPermissionResponseSchema,
  })
  .strict();

const ccbuddyProtocolMcpEntrySchema = z
  .object({
    name: nonEmptyString,
    value: z.string(),
  })
  .strict();

const ccbuddyProtocolMcpOAuthSchema = z.union([
  z
    .object({
      type: z.literal("client_credentials"),
      clientId: nonEmptyString,
      clientSecret: nonEmptyString,
      clientName: nonEmptyString.optional(),
      scope: z.string().optional(),
    })
    .strict(),
  z
    .object({
      type: z.literal("authorization_code"),
      clientId: nonEmptyString.optional(),
      clientSecret: nonEmptyString.optional(),
      clientName: nonEmptyString.optional(),
      redirectPath: nonEmptyString.optional(),
      scope: z.string().optional(),
    })
    .strict(),
]);

export const ccbuddyProtocolMcpServerSchema = z.union([
  z
    .object({
      name: nonEmptyString,
      command: nonEmptyString,
      args: z.array(z.string()),
      env: z.array(ccbuddyProtocolMcpEntrySchema),
      isolation: z.enum(["session", "workspace"]).optional(),
      protocolVersion: z.enum(["legacy", "auto", "2026-07-28"]).optional(),
      timeoutMs: z.number().int().positive().optional(),
    })
    .strict(),
  z
    .object({
      name: nonEmptyString,
      type: z.enum(["http", "sse"]),
      url: nonEmptyString,
      headers: z.array(ccbuddyProtocolMcpEntrySchema),
      oauth: ccbuddyProtocolMcpOAuthSchema.optional(),
      isolation: z.enum(["session", "workspace"]).optional(),
      protocolVersion: z.enum(["legacy", "auto", "2026-07-28"]).optional(),
      timeoutMs: z.number().int().positive().optional(),
    })
    .strict(),
]);
export type CCbuddyProtocolMcpServer = z.infer<typeof ccbuddyProtocolMcpServerSchema>;

export const ccbuddyMcpServerStatusKindSchema = z.enum([
  "connecting",
  "connected",
  "disabled",
  "disconnected",
  "failed",
  "untrusted",
]);
export const MCP_SERVER_FAILURE_KINDS = [
  "config_invalid",
  "runtime_unavailable",
  "process_start_failed",
  "network_unreachable",
  "connection_timeout",
  "protocol_negotiation_failed",
  "tool_list_failed",
  "unexpected_disconnect",
  "oauth_authorization_failed",
  "official_origin_untrusted",
  "not_authenticated",
  "coding_plan_required",
  "server_not_found",
  "server_unavailable",
  "rate_limited",
  "server_internal_error",
  "protocol_error",
  "status_unavailable",
  "connection_failed",
] as const;
export const mcpServerFailureKindSchema = z.enum(MCP_SERVER_FAILURE_KINDS);
export type McpServerFailureKind = z.infer<typeof mcpServerFailureKindSchema>;
export const ccbuddyMcpServerStatusSnapshotSchema = z
  .object({
    status: ccbuddyMcpServerStatusKindSchema,
    transport: z.enum(["stdio", "http", "sse"]),
    toolCount: z.number().int().nonnegative(),
    updatedAt: nonEmptyString,
    error: z.string().optional(),
    failureKind: mcpServerFailureKindSchema.optional(),
    serverRequestId: nonEmptyString.optional(),
    protocolEra: z.enum(["legacy", "modern"]).optional(),
    authorization: z
      .object({
        type: z.literal("oauth_authorization_code"),
        authorizationUrl: nonEmptyString,
        startedAt: nonEmptyString,
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddyMcpServerStatusSnapshot = z.infer<typeof ccbuddyMcpServerStatusSnapshotSchema>;

export const ccbuddyMcpListModeSchema = z.enum(["connect", "status"]);
export type CCbuddyMcpListMode = z.infer<typeof ccbuddyMcpListModeSchema>;

export const ccbuddyMcpListParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    mcpServers: z.array(ccbuddyProtocolMcpServerSchema).optional(),
    mode: ccbuddyMcpListModeSchema.default("connect"),
  })
  .strict();
export const ccbuddyMcpListResultSchema = z
  .object({
    statuses: z.record(z.string(), ccbuddyMcpServerStatusSnapshotSchema),
  })
  .strict();
export type CCbuddyMcpListResult = z.infer<typeof ccbuddyMcpListResultSchema>;

export const ccbuddySessionImportMessageSchema = z
  .object({
    role: z.enum(["user", "assistant"]),
    content: z.string(),
    timestamp: timestampMsSchema.optional(),
  })
  .strict();
export type CCbuddySessionImportMessage = z.infer<typeof ccbuddySessionImportMessageSchema>;

export const ccbuddySessionImportHistorySchema = z.discriminatedUnion("source", [
  z
    .object({
      source: z.literal("claudeCode"),
      title: z.string().optional(),
      createdAt: timestampMsSchema.optional(),
      updatedAt: timestampMsSchema.optional(),
      messages: z.array(ccbuddySessionImportMessageSchema).min(1),
    })
    .strict(),
  z
    .object({
      source: z.literal("sharedContext"),
      title: z.string().trim().min(1),
      createdAt: timestampMsSchema.optional(),
      markdown: z.string().min(1),
      provenance: z
        .object({
          shareId: z.string().trim().min(1),
          contextId: z.string().trim().min(1).optional(),
          shareUrl: z.string().url().optional(),
          status: z.enum(["pending", "reserved", "attached", "discarded"]).optional(),
          projectionSha256: z.string().regex(/^[0-9a-f]{64}$/u),
          artifactSetSha256: z.string().regex(/^[0-9a-f]{64}$/u),
          formatterVersion: z.literal(1),
          markdownSha256: z.string().regex(/^[0-9a-f]{64}$/u),
          installedArtifacts: z.array(
            z
              .object({
                artifactId: z.string().trim().min(1),
                workspaceRelativePath: z.string().trim().min(1),
              })
              .strict(),
          ),
        })
        .strict(),
    })
    .strict(),
]);
export type CCbuddySessionImportHistory = z.infer<typeof ccbuddySessionImportHistorySchema>;

export const ccbuddyThoughtLevelOptionSchema = z
  .object({
    value: nonEmptyString,
    label: nonEmptyString,
    description: z.string().optional(),
  })
  .strict();
export const ccbuddyModelReasoningOptionsSchema = z
  .object({
    levels: z.array(ccbuddyThoughtLevelOptionSchema),
    defaultLevel: nonEmptyString.optional(),
  })
  .strict();
export type CCbuddyModelReasoningOptions = z.infer<typeof ccbuddyModelReasoningOptionsSchema>;

export const ccbuddyModelFormatPropertiesSchema = completeModelPropertiesDataSchema.pick({
  inputFormat: true,
  outputFormat: true,
});
export type CCbuddyModelFormatProperties = z.infer<typeof ccbuddyModelFormatPropertiesSchema>;

export const ccbuddyModelOptionSchema = z
  .object({
    ref: modelSelectionSchema,
    label: nonEmptyString,
    providerLabel: nonEmptyString.optional(),
    description: z.string().optional(),
    contextWindow: z.number().int().positive().optional(),
    maxOutputTokens: z.number().int().positive().optional(),
    reasoning: ccbuddyModelReasoningOptionsSchema.optional(),
    properties: ccbuddyModelFormatPropertiesSchema,
    disabledReason: z.string().optional(),
  })
  .strict();
export type CCbuddyModelOption = z.infer<typeof ccbuddyModelOptionSchema>;

export const ccbuddyAccountAccessSchema = z.discriminatedUnion("planKind", [
  z
    .object({
      type: z.literal("zhipu-account"),
      family: z.enum(["zai", "bigmodel"]),
      planKind: z.literal("start-plan"),
    })
    .strict(),
  z
    .object({
      type: z.literal("zhipu-account"),
      family: z.enum(["zai", "bigmodel"]),
      planKind: z.literal("individual-coding-plan"),
    })
    .strict(),
  z
    .object({
      type: z.literal("zhipu-account"),
      family: z.enum(["zai", "bigmodel"]),
      planKind: z.literal("team-coding-plan"),
      productId: nonEmptyString,
      organizationId: nonEmptyString,
      projectId: nonEmptyString,
    })
    .strict(),
]);
export type CCbuddyAccountAccess = z.infer<typeof ccbuddyAccountAccessSchema>;

/** Active Model 固定的账号访问类别；当前商品和 Team scope 由账号服务在请求期解析。 */
export const ccbuddyProviderAccountAccessSchema = z
  .object({
    type: z.literal("zhipu-account"),
    accountType: z.enum(["zai", "bigmodel"]),
    mode: z.enum(["start-plan", "individual-coding-plan", "team-coding-plan", "off-peak"]),
    entitled: z.boolean(),
  })
  .strict();
export type CCbuddyProviderAccountAccess = z.infer<typeof ccbuddyProviderAccountAccessSchema>;

export type CCbuddySessionMode = z.infer<typeof ccbuddySessionModeSchema>;
export type CCbuddySessionKind = z.infer<typeof ccbuddySessionKindSchema>;
export type CCbuddySessionGoal = z.infer<typeof ccbuddySessionGoalSchema>;

export const ccbuddySessionTodoItemSchema = z
  .object({
    content: nonEmptyString,
    status: z.enum(["pending", "in_progress", "completed"]),
    priority: z.enum(["high", "medium", "low"]),
  })
  .strict();
export const ccbuddySessionGoalStatsSchema = z
  .object({
    timeUsedSeconds: z.number().int().nonnegative(),
    tokensUsed: z.number().int().nonnegative(),
    tokenBudget: z.number().int().positive().nullable(),
    contextUsed: z.number().int().nonnegative(),
    contextWindow: z.number().int().nonnegative(),
    toolCallCount: z.number().int().nonnegative(),
    iterationCount: z.number().int().nonnegative(),
  })
  .strict();
export type CCbuddySessionGoalStats = z.infer<typeof ccbuddySessionGoalStatsSchema>;
export type CCbuddySessionGoalVerification = z.infer<typeof ccbuddySessionGoalVerificationSchema>;
export type CCbuddySessionGoalVerificationTimeline = z.infer<
  typeof ccbuddySessionGoalVerificationTimelineSchema
>;

export const ccbuddySessionTodoGroupSchema = z
  .object({
    id: nonEmptyString,
    source: z.enum(["goal_iteration", "session"]),
    goalIteration: z.number().int().positive().optional(),
    targetId: nonEmptyString.optional(),
    startedAt: timestampMsSchema.optional(),
    updatedAt: timestampMsSchema.optional(),
    todos: z.array(ccbuddySessionTodoItemSchema),
  })
  .strict();
export type CCbuddySessionTodoGroup = z.infer<typeof ccbuddySessionTodoGroupSchema>;

export const ccbuddySessionSettingsStateSchema = z
  .object({
    model: z
      .object({
        // 未绑定是合法恢复状态；不能为满足协议而伪造模型或阻断历史读取。
        current: modelSelectionSchema.optional(),
        available: z.array(ccbuddyModelOptionSchema),
        lastUsed: modelSelectionSchema.optional(),
      })
      .strict(),
    thoughtLevel: z
      .object({
        enabled: z.boolean(),
        current: nonEmptyString.optional(),
        defaultLevel: nonEmptyString.optional(),
        available: z.array(ccbuddyThoughtLevelOptionSchema),
      })
      .strict(),
    mode: z
      .object({
        current: ccbuddySessionModeSchema,
      })
      .strict(),
    permission: z
      .object({
        mode: ccbuddySessionModeSchema.optional(),
        rulesRevision: z.number().int().nonnegative().optional(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddySessionSettingsState = z.infer<typeof ccbuddySessionSettingsStateSchema>;
export const ccbuddyPendingPermissionSchema = z
  .object({
    requestId: nonEmptyString,
    toolCallId: nonEmptyString,
    toolName: nonEmptyString,
    reason: z.string(),
    riskLevel: z.enum(["low", "medium", "high", "critical"]),
    input: z.unknown().optional(),
    origin: ccbuddyInteractionRequestOriginSchema.optional(),
    options: z.array(ccbuddyPermissionOptionSchema).min(1),
    requestedAt: timestampMsSchema,
  })
  .strict();
export type CCbuddyPendingPermission = z.infer<typeof ccbuddyPendingPermissionSchema>;

export const ccbuddyActiveToolCallSchema = z
  .object({
    toolCallId: nonEmptyString,
    toolName: nonEmptyString,
    status: z.enum(["pending", "running", "completed", "failed", "denied"]),
    startedAt: timestampMsSchema.optional(),
  })
  .strict();
export type CCbuddyActiveToolCall = z.infer<typeof ccbuddyActiveToolCallSchema>;

export const ccbuddySessionProjectionSchema = z
  .object({
    sessionId: nonEmptyString,
    status: ccbuddySessionStatusSchema,
    mode: ccbuddySessionModeSchema,
    turnCount: z.number().int().nonnegative(),
    totalTokenCount: z.number().int().nonnegative(),
    contextUsed: z.number().int().nonnegative(),
    contextWindow: z.number().int().nonnegative(),
    currentTurnId: nonEmptyString.optional(),
    pendingPermissions: z.array(ccbuddyPendingPermissionSchema),
    activeToolCalls: z.array(ccbuddyActiveToolCallSchema),
    backgroundJobs: z.array(jsonObjectSchema),
    target: ccbuddySessionGoalSchema.nullable().optional(),
    lastError: z
      .object({
        type: nonEmptyString,
        code: nonEmptyString.optional(),
        message: nonEmptyString,
        detail: z.string().optional(),
        attribution: errorAttributionSchema.optional(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddySessionProjection = z.infer<typeof ccbuddySessionProjectionSchema>;
export type CCbuddyToolState = z.infer<typeof ccbuddyToolStateSchema>;
export const ccbuddySlashCommandSchema = z
  .object({
    name: nonEmptyString,
    description: z.string(),
    inputHint: z.string().optional(),
    source: z.enum(["builtin", "custom"]).optional(),
  })
  .strict();
export type CCbuddySessionApiRetryStatus = z.infer<typeof ccbuddySessionApiRetryStatusSchema>;
export type CCbuddySessionContextUsage = z.infer<typeof ccbuddySessionContextUsageSchema>;
export const ccbuddyModelStreamingKindSchema = z.enum([
  "start",
  "finish",
  "error",
  "text_start",
  "text_delta",
  "text_end",
  "reasoning_start",
  "reasoning_delta",
  "reasoning_end",
  "tool_input_start",
  "tool_input_delta",
  "tool_input_end",
  "tool_call",
]);
export const ccbuddyModelStreamingEventPayloadSchema = z
  .object({
    assistantMessageId: z.string().optional(),
    delta: z.string().optional(),
    done: z.boolean().optional(),
    input: z.unknown().optional(),
    kind: ccbuddyModelStreamingKindSchema,
    partId: z.string().optional(),
    providerExecuted: z.boolean().optional(),
    toolCallId: z.string().optional(),
    toolName: z.string().optional(),
  })
  .strict();
export const ccbuddySessionStateSnapshotSchema = z
  .object({
    protocol: z
      .object({
        name: z.literal(CCBUDDY_PROTOCOL_NAME),
        version: z.literal(CCBUDDY_PROTOCOL_VERSION),
      })
      .strict(),
    session: ccbuddySessionInfoSchema,
    settings: ccbuddySessionSettingsStateSchema,
    projection: ccbuddySessionProjectionSchema,
    runtime: ccbuddySessionRuntimeStateSchema,
    messages: z.array(ccbuddyMessageWithPartsSchema),
    goalStats: ccbuddySessionGoalStatsSchema.optional(),
    todos: z.array(ccbuddySessionTodoItemSchema).optional(),
    todoGroups: z.array(ccbuddySessionTodoGroupSchema).optional(),
    slashCommands: z.array(ccbuddySlashCommandSchema).optional(),
  })
  .strict();
export type CCbuddySessionStateSnapshot = z.infer<typeof ccbuddySessionStateSnapshotSchema>;

export const ccbuddyEventEnvelopeSchema = z
  .object({
    eventId: nonEmptyString,
    sessionId: nonEmptyString,
    turnId: nonEmptyString.optional(),
    seq: z.number().int().nonnegative(),
    traceId: nonEmptyString.optional(),
    timestamp: timestampMsSchema,
    deliveryKind: ccbuddyDeliveryKindSchema.optional(),
  })
  .strict();

const ccbuddyComputerUseOperationEventBaseSchema = z
  .object({
    eventId: nonEmptyString,
    sequenceNumber: z.number().int().nonnegative(),
    sessionId: nonEmptyString,
    timestamp: timestampMsSchema,
  })
  .strict();

const ccbuddyComputerUseTurnStartedEventSchema = ccbuddyComputerUseOperationEventBaseSchema.extend({
  kind: z.literal("turn-started"),
  turnId: nonEmptyString,
});
const ccbuddyComputerUseTurnCompletedEventSchema =
  ccbuddyComputerUseOperationEventBaseSchema.extend({
    kind: z.literal("turn-completed"),
    turnId: nonEmptyString,
  });
const ccbuddyComputerUseTurnFailedEventSchema = ccbuddyComputerUseOperationEventBaseSchema.extend({
  kind: z.literal("turn-failed"),
  turnId: nonEmptyString,
});
const ccbuddyComputerUseToolScheduledEventSchema =
  ccbuddyComputerUseOperationEventBaseSchema.extend({
    kind: z.literal("tool-scheduled"),
    turnId: nonEmptyString,
    toolCallId: nonEmptyString,
    toolName: nonEmptyString,
    // 这个 cell 是否在用 Computer Use。只表达布尔事实，不再携带动作名——旧的
    // operationAction 靠从模型源码里抽取动作名得到，SDK 面一变就整体失配（见
    // bootstrap/src/ccbuddy-protocol/computer-use-operation-event.ts 的 usesComputerUse）。
    // 只挂在 scheduled 上：ToolCallStartedPayload 没有 input，start 时已拿不到模型源码。
    computerUse: z.literal(true).optional(),
  });
const ccbuddyComputerUseToolStartedEventSchema = ccbuddyComputerUseOperationEventBaseSchema.extend({
  kind: z.literal("tool-started"),
  turnId: nonEmptyString.optional(),
  toolCallId: nonEmptyString,
  toolName: nonEmptyString.optional(),
});
const ccbuddyComputerUseSessionClosedEventSchema =
  ccbuddyComputerUseOperationEventBaseSchema.extend({
    kind: z.literal("session-closed"),
  });

export const ccbuddyComputerUseOperationEventSchema = z.discriminatedUnion("kind", [
  ccbuddyComputerUseTurnStartedEventSchema,
  ccbuddyComputerUseTurnCompletedEventSchema,
  ccbuddyComputerUseTurnFailedEventSchema,
  ccbuddyComputerUseToolScheduledEventSchema,
  ccbuddyComputerUseToolStartedEventSchema,
  ccbuddyComputerUseSessionClosedEventSchema,
]);
export type CCbuddyComputerUseOperationEvent = z.infer<
  typeof ccbuddyComputerUseOperationEventSchema
>;

export const ccbuddySessionEventTypeSchema = z.enum([
  "session.created",
  "session.resumed",
  "session.updated",
  "session.titleUpdated",
  "session.closed",
  "turn.started",
  "turn.steerQueued",
  "turn.steerDrained",
  "turn.completed",
  "turn.failed",
  "message.upserted",
  "message.removed",
  "part.started",
  "part.delta",
  "part.upserted",
  "part.removed",
  "model.streaming",
  "tool.updated",
  "permission.requested",
  "permission.resolved",
  "userInput.requested",
  "userInput.resolved",
  "checkpoint.created",
  "rewind.triggered",
  "streamRecovery.updated",
]);
export type CCbuddySessionEventType = z.infer<typeof ccbuddySessionEventTypeSchema>;

export const ccbuddyProtocolErrorDetailSchema = z
  .object({
    type: nonEmptyString,
    message: nonEmptyString,
    stack: z.string().optional(),
    code: z.string().optional(),
    detail: z.string().optional(),
    underlyingErrorMessage: z.string().optional(),
    underlyingErrorDetail: z.string().optional(),
    attribution: errorAttributionSchema.optional(),
    retryable: z.boolean().optional(),
    data: z.unknown().optional(),
  })
  .strict();
export const ccbuddySessionCreatedEventPayloadSchema = z
  .object({
    mode: ccbuddySessionModeSchema,
    contextWindow: z.number().int().nonnegative(),
  })
  .strict();
export const ccbuddySessionResumedEventPayloadSchema = z
  .object({
    directory: nonEmptyString,
    interruptedToolCount: z.number().int().nonnegative(),
    messageCount: z.number().int().nonnegative(),
    partCount: z.number().int().nonnegative(),
    recoveredCompactTimelineCount: z.number().int().nonnegative().optional(),
    recoveredSteerInputCount: z.number().int().nonnegative().optional(),
    resumedTodoCount: z.number().int().nonnegative().optional(),
  })
  .strict();
export const ccbuddySessionTitleUpdatedEventPayloadSchema = z
  .object({
    messageID: nonEmptyString.optional(),
    previousTitle: z.string(),
    source: z.enum(["default", "first_input", "generated", "custom"]),
    title: z.string(),
  })
  .strict();
export const ccbuddyTurnStartedEventPayloadSchema = z
  .object({
    turnNumber: z.number().int().nonnegative(),
    input: z.string(),
    inputId: nonEmptyString.optional(),
    queryId: nonEmptyString.optional(),
    inputSource: ccbuddyTurnInputSourceSchema.optional(),
    inputVisibility: ccbuddyMessageVisibilitySchema.optional(),
    executionKind: z.enum(["agent", "controlOnly"]).optional(),
    targetId: nonEmptyString.optional(),
    messageId: nonEmptyString.optional(),
    foregroundExecutionId: nonEmptyString.optional(),
    intent: jsonObjectSchema.optional(),
    originMeta: jsonObjectSchema.optional(),
    // runtime 会透传后台唤醒来源，strict schema 必须同步声明以免丢弃整条事件。
    backgroundSource: z.enum(["bash", "subagent"]).optional(),
    attachments: z.array(jsonObjectSchema).optional(),
  })
  .strict();
const ccbuddyTurnSteerSourceSchema = z.enum(["plan_approval_feedback", "workflow_refine_feedback"]);
const ccbuddyTurnSteerCommandKindSchema = z.enum(["sendText", "sendGoalCommand", "compact"]);
const ccbuddyTurnSteerDeliverySchema = z.enum(["queue", "guide"]);

export const ccbuddyTurnSteerQueuedEventPayloadSchema = z
  .object({
    pendingInputId: nonEmptyString,
    inputId: nonEmptyString.optional(),
    queryId: nonEmptyString.optional(),
    input: z.string(),
    inputPreview: z.string(),
    inputSize: z.number().int().nonnegative(),
    commandKind: ccbuddyTurnSteerCommandKindSchema.optional(),
    source: ccbuddyTurnSteerSourceSchema.optional(),
    toolDisallowlist: z.array(nonEmptyString).optional(),
    delivery: ccbuddyTurnSteerDeliverySchema.optional(),
    targetTurnId: nonEmptyString,
    queueLength: z.number().int().nonnegative(),
    intent: jsonObjectSchema.optional(),
  })
  .strict();
export const ccbuddyTurnSteerDrainedEventPayloadSchema = z
  .object({
    pendingInputIds: z.array(nonEmptyString),
    queryIds: z.array(nonEmptyString).optional(),
    targetTurnId: nonEmptyString,
    injectedMessageIds: z.array(nonEmptyString),
    drainedInputs: z
      .array(
        z
          .object({
            pendingInputId: nonEmptyString,
            messageId: nonEmptyString,
            text: z.string(),
            delivery: ccbuddyTurnSteerDeliverySchema.optional(),
            intent: jsonObjectSchema.optional(),
            toolDisallowlist: z.array(nonEmptyString).optional(),
          })
          .strict(),
      )
      .optional(),
  })
  .strict();
export const ccbuddyTurnCompletedEventPayloadSchema = z
  .object({
    response: z.string(),
    tokenCount: z.number().int().nonnegative(),
    usage: z.unknown().optional(),
    toolCallCount: z.number().int().nonnegative(),
    historyRoundCount: z.number().int().nonnegative().optional(),
    duration: z.number().nonnegative(),
    // runtime turn.completed 会附带 cacheStats，协议 schema 之前漏掉该字段。
    // strict 校验失败会让桌面端丢掉终态事件，表现为消息已完成但 UI 一直没有回复。
    cacheStats: z
      .object({
        totalMessages: z.number().int().nonnegative(),
        cachedMessages: z.number().int().nonnegative(),
        lastCacheHit: z.boolean(),
        cacheReadTokens: z.number().int().nonnegative().optional(),
      })
      .strict()
      .optional(),
    inputId: nonEmptyString.optional(),
    resultType: z.enum([
      "success",
      // "cancelled": 用户主动中断属于正常结束，复用 turn.completed 上报，避免被映射成 turn.failed。
      "cancelled",
      "error_max_turns",
      "error_max_budget",
      "error_during_execution",
      "error_max_tool_calls",
    ]),
    backgroundSubagentResultConsumed: z.boolean().optional(),
  })
  .strict();
export const ccbuddyTurnFailedEventPayloadSchema = z
  .object({
    error: ccbuddyProtocolErrorDetailSchema,
    turnPhase: z.string(),
    inputId: nonEmptyString.optional(),
    backgroundSubagentResultConsumed: z.boolean().optional(),
  })
  .strict();
export const ccbuddyMessageUpsertedEventPayloadSchema = z
  .object({
    content: z.string(),
    attachments: z.array(z.unknown()).optional(),
    toolCalls: z.array(z.unknown()).optional(),
    type: z.string().optional(),
    compactBoundary: z.unknown().optional(),
  })
  .strict();
export const ccbuddyMessageRemovedEventPayloadSchema = z
  .object({
    messageId: nonEmptyString,
    reason: z.string().optional(),
  })
  .strict();
export const ccbuddyMessagePartDeltaEventPayloadSchema = z
  .object({
    messageId: nonEmptyString,
    partId: nonEmptyString,
    field: z.enum(["text", "reasoning", "input", "output"]).optional(),
    delta: z.string(),
  })
  .strict();
export const ccbuddyMessagePartUpsertedEventPayloadSchema = z
  .object({
    part: ccbuddyMessagePartSchema,
  })
  .strict();
export const ccbuddyMessagePartRemovedEventPayloadSchema = z
  .object({
    messageId: nonEmptyString,
    partId: nonEmptyString,
    reason: z.string().optional(),
  })
  .strict();
const ccbuddyToolCallBasePayloadSchema = z
  .object({
    toolCallId: nonEmptyString,
    toolName: z.string().optional(),
    parentToolCallId: nonEmptyString.optional(),
    source: z.enum(["subagent"]).optional(),
    agentId: nonEmptyString.optional(),
    agentType: nonEmptyString.optional(),
    // subagent mirror 会携带后台归因；strict schema 漏字段会让 session/event 整条被丢弃。
    background: z.boolean().optional(),
    childSessionId: nonEmptyString.optional(),
    childToolCallId: nonEmptyString.optional(),
    description: z.string().optional(),
  })
  .strict();

export const ccbuddyToolUpdatedEventPayloadSchema = z.discriminatedUnion("kind", [
  ccbuddyToolCallBasePayloadSchema
    .extend({
      kind: z.literal("scheduled"),
      // 修复：CLI 调度事件已携带所属消息 ID；漏声明会让严格校验丢弃整条事件。
      assistantMessageId: nonEmptyString.optional(),
      toolName: nonEmptyString,
      input: z.unknown().optional(),
      inputByteLength: z.number().int().nonnegative().optional(),
      inputOmitted: z.boolean().optional(),
      inputRef: z.literal("model_stream").optional(),
      dependencies: z.array(nonEmptyString).optional(),
      parallelGroupIndex: z.number().int().nonnegative().optional(),
      canRunParallel: z.boolean().optional(),
      schedule: jsonObjectSchema.optional(),
    })
    .strict(),
  ccbuddyToolCallBasePayloadSchema
    .extend({
      kind: z.literal("started"),
      startedAt: protocolInstantSchema,
    })
    .strict(),
  ccbuddyToolCallBasePayloadSchema
    .extend({
      kind: z.literal("progress"),
      elapsedMs: z.number().nonnegative().optional(),
      pid: z.number().int().optional(),
      stdoutBytes: z.number().int().nonnegative().optional(),
      stderrBytes: z.number().int().nonnegative().optional(),
      outputBytes: z.number().int().nonnegative().optional(),
      outputPreview: executionOutputPreviewSchema.optional(),
      stdoutTail: z.string().optional(),
      stderrTail: z.string().optional(),
    })
    .strict(),
  ccbuddyToolCallBasePayloadSchema
    .extend({
      kind: z.literal("result"),
      result: ccbuddyToolResultObjectSchema,
      duration: z.number().nonnegative(),
    })
    .strict(),
  ccbuddyToolCallBasePayloadSchema
    .extend({
      kind: z.literal("error"),
      error: ccbuddyProtocolErrorDetailSchema,
    })
    .strict(),
  z
    .object({
      kind: z.literal("batch"),
      toolCallIds: z.array(nonEmptyString),
      successCount: z.number().int().nonnegative(),
      errorCount: z.number().int().nonnegative(),
    })
    .strict(),
  ccbuddyToolCallBasePayloadSchema
    .extend({
      kind: z.literal("raw"),
      payload: jsonObjectSchema,
    })
    .strict(),
]);
export const ccbuddyPermissionRequestedEventPayloadSchema = z
  .object({
    requestId: nonEmptyString.optional(),
    toolCallId: nonEmptyString,
    toolName: nonEmptyString,
    riskLevel: z.enum(["low", "medium", "high", "critical"]),
    reason: z.string(),
    input: z.unknown(),
    suggestedPermissionUpdates: z.array(ccbuddyPermissionUpdateSchema).optional(),
    origin: ccbuddyInteractionRequestOriginSchema.optional(),
    options: z.array(ccbuddyPermissionOptionSchema).min(1),
    childSessionId: nonEmptyString.optional(),
    background: z.boolean().optional(),
  })
  .strict();
export const ccbuddyPermissionResolvedEventPayloadSchema = z
  .object({
    requestId: nonEmptyString.optional(),
    toolCallId: nonEmptyString,
    toolName: nonEmptyString.optional(),
    decision: ccbuddyPermissionDecisionSchema.optional(),
    reason: z.string().optional(),
    modifiedInput: z.unknown().optional(),
    inputSummary: z.unknown().optional(),
    childSessionId: nonEmptyString.optional(),
    background: z.boolean().optional(),
  })
  .strict();
export const ccbuddyUserInputRequestedEventPayloadSchema = z
  .object({
    requestId: nonEmptyString,
    prompt: z.string(),
    inputType: z.enum(["text", "choice", "confirm"]).optional(),
    choices: z.array(z.string()).optional(),
  })
  .strict();
export const ccbuddyUserInputResolvedEventPayloadSchema = z
  .object({
    requestId: nonEmptyString,
    value: z.unknown().optional(),
    cancelled: z.boolean().optional(),
  })
  .strict();
export const ccbuddySessionClosedEventPayloadSchema = z
  .object({
    reason: z.string().optional(),
  })
  .strict();

function ccbuddySessionEventEnvelopeFor<T extends CCbuddySessionEventType>(
  type: T,
  payload: z.ZodTypeAny,
) {
  return ccbuddyEventEnvelopeSchema.extend({
    type: z.literal(type),
    payload: payload.optional(),
  });
}

export const ccbuddySessionEventSchema = z.discriminatedUnion("type", [
  ccbuddySessionEventEnvelopeFor("session.created", ccbuddySessionCreatedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("session.resumed", ccbuddySessionResumedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("session.updated", jsonObjectSchema),
  ccbuddySessionEventEnvelopeFor(
    "session.titleUpdated",
    ccbuddySessionTitleUpdatedEventPayloadSchema,
  ),
  ccbuddySessionEventEnvelopeFor("session.closed", ccbuddySessionClosedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("turn.started", ccbuddyTurnStartedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("turn.steerQueued", ccbuddyTurnSteerQueuedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("turn.steerDrained", ccbuddyTurnSteerDrainedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("turn.completed", ccbuddyTurnCompletedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("turn.failed", ccbuddyTurnFailedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("message.upserted", ccbuddyMessageUpsertedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("message.removed", ccbuddyMessageRemovedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("part.started", ccbuddyMessagePartUpsertedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("part.delta", ccbuddyMessagePartDeltaEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("part.upserted", ccbuddyMessagePartUpsertedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("part.removed", ccbuddyMessagePartRemovedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("model.streaming", ccbuddyModelStreamingEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("tool.updated", ccbuddyToolUpdatedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor(
    "permission.requested",
    ccbuddyPermissionRequestedEventPayloadSchema,
  ),
  ccbuddySessionEventEnvelopeFor(
    "permission.resolved",
    ccbuddyPermissionResolvedEventPayloadSchema,
  ),
  ccbuddySessionEventEnvelopeFor(
    "userInput.requested",
    ccbuddyUserInputRequestedEventPayloadSchema,
  ),
  ccbuddySessionEventEnvelopeFor("userInput.resolved", ccbuddyUserInputResolvedEventPayloadSchema),
  ccbuddySessionEventEnvelopeFor("checkpoint.created", jsonObjectSchema),
  ccbuddySessionEventEnvelopeFor("rewind.triggered", jsonObjectSchema),
  ccbuddySessionEventEnvelopeFor("streamRecovery.updated", jsonObjectSchema),
]);
export type CCbuddySessionEvent = z.infer<typeof ccbuddySessionEventSchema>;

export const ccbuddySessionEventsResultSchema = z
  .object({
    events: z.array(ccbuddySessionEventSchema),
  })
  .strict();
export const ccbuddySessionMessagesResultSchema = z
  .object({
    messages: z.array(ccbuddyMessageWithPartsSchema),
  })
  .strict();
export const ccbuddyStateUpdatedNotificationSchema = z
  .object({
    type: z.literal("state.updated"),
    scope: z.enum(["server", "workspace", "session"]),
    workspace: ccbuddyWorkspaceRefSchema.optional(),
    sessionId: nonEmptyString.optional(),
    revision: z.number().int().nonnegative(),
    reason: z.string().optional(),
    patch: z.unknown(),
  })
  .strict();
export type CCbuddyStateUpdatedNotification = z.infer<typeof ccbuddyStateUpdatedNotificationSchema>;

export const ccbuddySessionSubscribeParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    deliveryKind: ccbuddyDeliveryKindSchema,
    afterSeq: z.number().int().nonnegative().optional(),
    includeSnapshot: z.boolean().default(false),
  })
  .strict();
export type CCbuddySessionSubscribeParams = z.infer<typeof ccbuddySessionSubscribeParamsSchema>;

export const ccbuddySessionSubscribeResultSchema = z
  .object({
    sessionId: nonEmptyString,
    eventSeq: z.number().int().nonnegative(),
    events: z.array(ccbuddySessionEventSchema),
    snapshot: ccbuddySessionStateSnapshotSchema.optional(),
  })
  .strict();
export const ccbuddySessionListResultSchema = z
  .object({
    sessions: z.array(ccbuddySessionInfoSchema),
  })
  .strict();

const ccbuddySessionSubagentBaseSchema = z
  .object({
    childSessionId: nonEmptyString,
    agentId: nonEmptyString.optional(),
    toolCallId: nonEmptyString.optional(),
    subagentType: nonEmptyString,
    title: nonEmptyString,
    summary: z.string().optional(),
    startedAt: z.number().int().nonnegative().optional(),
    endedAt: z.number().int().nonnegative().optional(),
  })
  .strict();

export const ccbuddySessionRunningSubagentSchema = ccbuddySessionSubagentBaseSchema.extend({
  status: z.enum(["running", "waiting", "blocked"]),
});
export type CCbuddySessionRunningSubagent = z.infer<typeof ccbuddySessionRunningSubagentSchema>;

export const ccbuddySessionEndedSubagentSchema = ccbuddySessionSubagentBaseSchema.extend({
  status: z.enum(["success", "failed", "cancelled", "lost"]),
});
export type CCbuddySessionEndedSubagent = z.infer<typeof ccbuddySessionEndedSubagentSchema>;

export const ccbuddySessionSubagentsResultSchema = z
  .object({
    revision: z.number().int().nonnegative(),
    childSessionIds: z.array(nonEmptyString),
    running: z.array(ccbuddySessionRunningSubagentSchema),
    ended: z
      .object({
        total: z.number().int().nonnegative(),
        items: z.array(ccbuddySessionEndedSubagentSchema),
        nextCursor: nonEmptyString.optional(),
      })
      .strict(),
  })
  .strict();
export type CCbuddySessionSubagentsResult = z.infer<typeof ccbuddySessionSubagentsResultSchema>;
export const ccbuddySessionCreateParamsSchema = z
  .object({
    sessionId: nonEmptyString.optional(),
    workspace: ccbuddyWorkspaceRefSchema,
    parentSessionId: nonEmptyString.optional(),
    mode: ccbuddySessionModeSchema.optional(),
    model: modelSelectionSchema.optional(),
    persistence: ccbuddySessionPersistenceSchema.optional(),
    thoughtLevel: nonEmptyString.optional(),
    titleGenerationEnabled: z.boolean().optional(),
    mcpServers: z.array(ccbuddyProtocolMcpServerSchema).optional(),
    toolAllowlist: z.array(nonEmptyString).optional(),
    toolDenylist: z.array(nonEmptyString).optional(),
    importedHistory: ccbuddySessionImportHistorySchema.optional(),
    // host 只按本地服务装配/远程/端形态决定是否注册工具，不读取灰度；
    // 缺省不下发 = 不注册；灰度与套餐准入在实际创建的 Host handler 校验。
    offPeakToolEnabled: z.boolean().optional(),
    // 动态工作流灰度：与 offPeakToolEnabled 同一
    // 模式——host 裁决后下发，缺省不下发 = 不注册工作流工具簇（fail-closed）。
    dynamicWorkflowEnabled: z.boolean().optional(),
  })
  .strict();
export type CCbuddySessionCreateParams = z.infer<typeof ccbuddySessionCreateParamsSchema>;

export const ccbuddySessionResumeParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    workspace: ccbuddyWorkspaceRefSchema.optional(),
    // 旧 session 尚无 runtime/model_selection entry 时，由同 task 的索引元数据提供迁移 hint。
    thoughtLevel: nonEmptyString.optional(),
    mcpServers: z.array(ccbuddyProtocolMcpServerSchema).optional(),
    // 冷恢复重建 runtime 时必须沿用 create 的工具面约束（否则会绕过 allow/deny，尤其 CUA 会话）。
    toolAllowlist: z.array(nonEmptyString).optional(),
    toolDenylist: z.array(nonEmptyString).optional(),
    // 与 create 同语义；resume 不带会导致冷恢复丢 Off-Peak 工具面。
    offPeakToolEnabled: z.boolean().optional(),
    // 与 create 同语义；resume 不带会导致冷恢复丢工作流工具簇。
    dynamicWorkflowEnabled: z.boolean().optional(),
  })
  .strict();
export type CCbuddySessionResumeParams = z.infer<typeof ccbuddySessionResumeParamsSchema>;

export const ccbuddySessionListParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema.optional(),
    // 显式身份查询包含隐藏会话；普通列表仍只返回主任务，避免索引修复激活 runtime。
    sessionIds: z.array(nonEmptyString).min(1).max(64).optional(),
    includeArchived: z.boolean().default(false),
    limit: z.number().int().positive().optional(),
  })
  .strict();
export type CCbuddySessionListParams = z.infer<typeof ccbuddySessionListParamsSchema>;

export const ccbuddySessionSubagentsParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    endedCursor: nonEmptyString.optional(),
    endedLimit: z.number().int().positive().max(100).default(20),
  })
  .strict();
export type CCbuddySessionSubagentsParams = z.infer<typeof ccbuddySessionSubagentsParamsSchema>;

export const ccbuddyUsageStatsParamsSchema = z
  .object({
    range: z.enum(APP_USAGE_RANGES),
    timeZone: z.string().optional(),
  })
  .strict();
export const ccbuddyUsageStatsResultSchema = appUsageSnapshotSchema;
export const ccbuddyTaskTokenUsageParamsSchema = z
  .object({
    sessionId: nonEmptyString,
  })
  .strict();
export const ccbuddyTaskTokenUsageResultSchema = z
  .object({
    sessionId: nonEmptyString,
    totalTokens: z.number().int().nonnegative(),
    inputTokens: z.number().int().nonnegative(),
    outputTokens: z.number().int().nonnegative(),
    reasoningTokens: z.number().int().nonnegative(),
    cacheCreationTokens: z.number().int().nonnegative(),
    cacheReadTokens: z.number().int().nonnegative(),
    modelRequestCount: z.number().int().nonnegative(),
    modelErrorCount: z.number().int().nonnegative(),
    inputBaselineBySource: z.record(z.string(), z.number().int().nonnegative()),
  })
  .strict();
export type CCbuddyTaskTokenUsageResult = z.infer<typeof ccbuddyTaskTokenUsageResultSchema>;

export const ccbuddySessionReadParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    deliveryKind: ccbuddyDeliveryKindSchema.optional(),
    messageLimit: z.number().int().positive().optional(),
    afterSeq: z.number().int().nonnegative().optional(),
  })
  .strict();
export type CCbuddySessionReadParams = z.infer<typeof ccbuddySessionReadParamsSchema>;

export const ccbuddySessionMessagesParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    afterMessageId: nonEmptyString.optional(),
    limit: z.number().int().positive().optional(),
  })
  .strict();
export type CCbuddySessionMessagesParams = z.infer<typeof ccbuddySessionMessagesParamsSchema>;

export const ccbuddySessionEventsParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    afterSeq: z.number().int().nonnegative().optional(),
    limit: z.number().int().positive().optional(),
  })
  .strict();
export type CCbuddySessionEventsParams = z.infer<typeof ccbuddySessionEventsParamsSchema>;

export const ccbuddySessionRuntimePreferencesScopeSchema = z.enum([
  "runtime-materialization",
  "user-execution",
]);
export type CCbuddySessionRuntimePreferencesScope = z.infer<
  typeof ccbuddySessionRuntimePreferencesScopeSchema
>;

export const CCBUDDY_SESSION_RUNTIME_PREFERENCES_REQUEST_TIMEOUT_MS = 15_000;

export const ccbuddySessionRequestRuntimePreferencesParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    scope: ccbuddySessionRuntimePreferencesScopeSchema,
  })
  .strict();
export type CCbuddySessionRequestRuntimePreferencesParams = z.infer<
  typeof ccbuddySessionRequestRuntimePreferencesParamsSchema
>;

export const DEFAULT_CCBUDDY_MODEL_CONTEXT_BUDGET_STRATEGY = "preflight-v1" as const;

// 3.12.2：legacy 仅为旧协议接收兼容；Runtime 一律归一为上面的共享默认策略。
export const ccbuddyModelContextBudgetStrategySchema = z.enum(["legacy", "preflight-v1"]);
export type CCbuddyModelContextBudgetStrategy = z.infer<
  typeof ccbuddyModelContextBudgetStrategySchema
>;

export const ccbuddySessionRuntimePreferencesResultSchema = z
  .object({
    nativeSearchEnhancementsEnabled: z.boolean(),
    memoryEnabled: z.boolean().default(false),
    askUserQuestionAutoResolutionEnabled: z.boolean().default(true),
    integratedTerminalShell: integratedTerminalShellSelectionSchema.optional(),
    // 兼容旧 Host：缺少字段时在协议解析边界使用当前默认策略。
    modelContextBudgetStrategy: ccbuddyModelContextBudgetStrategySchema.default(
      DEFAULT_CCBUDDY_MODEL_CONTEXT_BUDGET_STRATEGY,
    ),
  })
  .strict();
export type CCbuddySessionRuntimePreferencesResult = z.infer<
  typeof ccbuddySessionRuntimePreferencesResultSchema
>;

/**
 * App 在提交 prompt 前只读采集的 IAB 可见状态。该字段只用于 provider-visible
 * ambient context，不进入用户可见 transcript；内容有界，禁止携带页面正文或凭据。
 */
export const ccbuddyBrowserAmbientContextSchema = z
  .object({
    tabCount: z.number().int().positive().max(100),
    currentUrl: z.string().trim().min(1).max(4096).optional(),
  })
  .strict();
export type CCbuddyBrowserAmbientContext = z.infer<typeof ccbuddyBrowserAmbientContextSchema>;

export const ccbuddySessionSendParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    modelSelection: modelSelectionSchema.optional(),
    modelExecution: modelExecutionSchema.optional(),
    inputId: nonEmptyString.optional(),
    queryId: nonEmptyString.optional(),
    content: z.string(),
    attachments: z.array(jsonObjectSchema).optional(),
    browserAmbientContext: ccbuddyBrowserAmbientContextSchema.optional(),
    expectedRevision: z.number().int().nonnegative().optional(),
    expectedProviderRevision: nonEmptyString.optional(),
    automationId: nonEmptyString.optional(),
    offPeakTaskId: nonEmptyString.optional(),
    offPeakRunType: z.enum(["init", "resume"]).optional(),
    botDeliveryTarget: ccbuddyAutomationBotDeliveryTargetSchema.optional(),
    toolDenylist: z.array(nonEmptyString).optional(),
  })
  .strict()
  .superRefine((payload, context) => {
    if (payload.automationId && payload.offPeakTaskId) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "automationId and offPeakTaskId are mutually exclusive",
      });
    }
    if (payload.offPeakRunType && !payload.offPeakTaskId) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "offPeakRunType requires offPeakTaskId",
        path: ["offPeakRunType"],
      });
    }
    if (payload.modelExecution && !payload.modelSelection) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "modelExecution requires modelSelection",
        path: ["modelExecution"],
      });
    }
  });
export const ccbuddySessionSendResultSchema = z
  .object({
    sessionId: nonEmptyString,
    accepted: z.literal(true),
    stateRevision: z.number().int().nonnegative(),
  })
  .strict();
export type CCbuddySessionSendResult = z.infer<typeof ccbuddySessionSendResultSchema>;

export const ccbuddySessionHistoryTargetSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("turn"),
      turnIndex: z.number().int().nonnegative(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("message"),
      messageId: nonEmptyString,
    })
    .strict(),
  z
    .object({
      kind: z.literal("checkpoint"),
      checkpointId: nonEmptyString,
    })
    .strict(),
  z
    .object({
      kind: z.literal("latestCheckpoint"),
    })
    .strict(),
]);
export type CCbuddySessionHistoryTarget = z.infer<typeof ccbuddySessionHistoryTargetSchema>;

export const ccbuddySessionForkParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    target: ccbuddySessionHistoryTargetSchema.default({
      kind: "latestCheckpoint",
    }),
    expectedRevision: z.number().int().nonnegative().optional(),
  })
  .strict();
export type CCbuddySessionForkParams = z.infer<typeof ccbuddySessionForkParamsSchema>;

export const ccbuddySessionForkResultSchema = z
  .object({
    forkedSessionId: nonEmptyString,
    parentSessionId: nonEmptyString.optional(),
    targetMessageId: nonEmptyString.optional(),
    targetCheckpointId: nonEmptyString.optional(),
    response: z.string(),
    snapshot: ccbuddySessionStateSnapshotSchema,
  })
  .strict();
export type CCbuddySessionForkResult = z.infer<typeof ccbuddySessionForkResultSchema>;

export const ccbuddySessionCompactParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    inputId: nonEmptyString.optional(),
    instructions: z.string().optional(),
    expectedRevision: z.number().int().nonnegative().optional(),
  })
  .strict();
export type CCbuddySessionCompactParams = z.infer<typeof ccbuddySessionCompactParamsSchema>;

export const ccbuddySessionCompactResultSchema = z
  .object({
    response: z.string(),
    snapshot: ccbuddySessionStateSnapshotSchema,
    compact: z
      .object({
        state: z.enum(["accepted", "already_running"]),
        inputId: nonEmptyString.optional(),
        operationId: nonEmptyString.optional(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddySessionCompactResult = z.infer<typeof ccbuddySessionCompactResultSchema>;

export const ccbuddySessionGoalActionSchema = z.enum([
  "show",
  "set",
  "replace",
  "pause",
  "resume",
  "clear",
]);
export type CCbuddySessionGoalAction = z.infer<typeof ccbuddySessionGoalActionSchema>;

export const ccbuddySessionGoalParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    inputId: nonEmptyString.optional(),
    action: ccbuddySessionGoalActionSchema,
    objective: z.string().optional(),
    expectedRevision: z.number().int().nonnegative().optional(),
  })
  .strict();
export type CCbuddySessionGoalParams = z.infer<typeof ccbuddySessionGoalParamsSchema>;

export const ccbuddySessionGoalResultSchema = z
  .object({
    response: z.string(),
    snapshot: ccbuddySessionStateSnapshotSchema,
    startedTurn: z.boolean().optional(),
  })
  .strict();
export type CCbuddySessionGoalResult = z.infer<typeof ccbuddySessionGoalResultSchema>;

export const ccbuddySessionStopParamsSchema = z
  .object({
    sessionId: nonEmptyString,
  })
  .strict();
const ccbuddyBackgroundTaskInfoStatusSchema = z.enum([
  "running",
  "completed",
  "failed",
  "timed_out",
  "cancelled",
  "spawn_error",
  "lost",
]);

export const ccbuddyBackgroundTaskInfoSchema = z
  .object({
    taskId: nonEmptyString,
    toolCallId: nonEmptyString.optional(),
    toolName: nonEmptyString.optional(),
    taskKind: z.enum(["bash", "subagent"]).optional(),
    blocked: z.boolean().optional(),
    blockedReason: z.string().optional(),
    cancellable: z.boolean().optional(),
    cancelRequestedAt: protocolInstantSchema.optional(),
    command: z.string().optional(),
    description: z.string().optional(),
    status: ccbuddyBackgroundTaskInfoStatusSchema,
    pid: z.number().int().positive().optional(),
    startedAt: protocolInstantSchema.optional(),
    completedAt: protocolInstantSchema.optional(),
    outputPath: z.string().optional(),
    stderrPersistedOutputPath: z.string().optional(),
    stdoutPersistedOutputPath: z.string().optional(),
    outputBytes: z.number().int().nonnegative().optional(),
    outputTruncated: z.boolean().optional(),
    outputTail: z.string().optional(),
    stderrBytes: z.number().int().nonnegative().optional(),
    stderrTail: z.string().optional(),
    stdoutBytes: z.number().int().nonnegative().optional(),
    stdoutTail: z.string().optional(),
    terminalId: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddySessionCancelBackgroundTaskParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    taskId: nonEmptyString,
  })
  .strict();
export type CCbuddySessionCancelBackgroundTaskParams = z.infer<
  typeof ccbuddySessionCancelBackgroundTaskParamsSchema
>;

export const ccbuddySessionCancelBackgroundTaskResultSchema = z
  .object({
    cancelled: z.boolean(),
    reason: z.string().optional(),
    snapshot: ccbuddyBackgroundTaskInfoSchema.optional(),
    status: ccbuddyBackgroundTaskInfoStatusSchema,
    taskId: nonEmptyString,
  })
  .strict();
export type CCbuddySessionCancelBackgroundTaskResult = z.infer<
  typeof ccbuddySessionCancelBackgroundTaskResultSchema
>;

export const ccbuddySessionSetModelParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    model: modelSelectionSchema,
    expectedRevision: z.number().int().nonnegative().optional(),
    persistAsWorkspaceLastUsed: z.boolean().default(true),
  })
  .strict();
export type CCbuddySessionSetModelParams = z.infer<typeof ccbuddySessionSetModelParamsSchema>;

export const ccbuddySessionSetThoughtLevelParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    thoughtLevel: nonEmptyString.optional(),
    expectedRevision: z.number().int().nonnegative().optional(),
    persistAsWorkspaceLastUsed: z.boolean().default(true),
  })
  .strict();
export type CCbuddySessionSetThoughtLevelParams = z.infer<
  typeof ccbuddySessionSetThoughtLevelParamsSchema
>;

export const ccbuddySessionSetModeParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    mode: ccbuddySessionModeSchema,
    expectedRevision: z.number().int().nonnegative().optional(),
  })
  .strict();
export type CCbuddySessionSetModeParams = z.infer<typeof ccbuddySessionSetModeParamsSchema>;

export const ccbuddySessionCloseParamsSchema = z
  .object({
    sessionId: nonEmptyString,
    expectedPersistence: ccbuddySessionPersistenceSchema.optional(),
  })
  .strict();
export type CCbuddySessionCloseParams = z.infer<typeof ccbuddySessionCloseParamsSchema>;
export const ccbuddySessionCloseResultSchema = z
  .object({
    closed: z.boolean().optional(),
  })
  .strict();
export type CCbuddySessionCloseResult = z.infer<typeof ccbuddySessionCloseResultSchema>;
export const ccbuddyWorkspaceReadPresentationParamsSchema = z
  .object({ workspace: ccbuddyWorkspaceRefSchema })
  .strict();
export const ccbuddyWorkspacePresentationSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    mode: ccbuddySessionModeSchema,
    slashCommands: z.array(ccbuddySlashCommandSchema),
  })
  .strict();
export type CCbuddyWorkspacePresentation = z.infer<typeof ccbuddyWorkspacePresentationSchema>;
const workspaceHookSha256DigestSchema = z.string().regex(/^[a-f0-9]{64}$/u);
export const ccbuddyWorkspaceHookTrustGrantParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    bundleDigest: workspaceHookSha256DigestSchema,
    hookDeclarationDigest: workspaceHookSha256DigestSchema,
  })
  .strict();
export type CCbuddyWorkspaceHookTrustGrantParams = z.infer<
  typeof ccbuddyWorkspaceHookTrustGrantParamsSchema
>;
export const ccbuddyWorkspaceHookTrustGrantReasonCodeSchema = z.enum([
  "workspace_hooks_blocked_by_policy",
  "workspace_hooks_bundle_changed",
  "workspace_hooks_snapshot_mismatch",
  "workspace_hooks_policy_requires_pretrust",
  "workspace_hooks_trust_store_corrupt",
  "workspace_hooks_config_unreadable",
]);
export type CCbuddyWorkspaceHookTrustGrantReasonCode = z.infer<
  typeof ccbuddyWorkspaceHookTrustGrantReasonCodeSchema
>;
export const ccbuddyWorkspaceHookTrustGrantResultSchema = z
  .object({
    accepted: z.boolean(),
    reasonCode: ccbuddyWorkspaceHookTrustGrantReasonCodeSchema.optional(),
  })
  .strict();
export type CCbuddyWorkspaceHookTrustGrantResult = z.infer<
  typeof ccbuddyWorkspaceHookTrustGrantResultSchema
>;
const ccbuddyWorkspaceModelToolCallSchema = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    input: z.unknown(),
  })
  .strict();
const ccbuddyWorkspaceModelMessageSchema = z.discriminatedUnion("role", [
  z.object({ role: z.literal("system"), content: z.string() }).strict(),
  z.object({ role: z.literal("user"), content: z.string() }).strict(),
  z
    .object({
      role: z.literal("assistant"),
      content: z.string(),
      toolCalls: z.array(ccbuddyWorkspaceModelToolCallSchema).optional(),
    })
    .strict(),
  z
    .object({
      role: z.literal("tool"),
      content: z.string(),
      toolCallId: nonEmptyString,
      toolName: nonEmptyString,
      isError: z.boolean().optional(),
    })
    .strict(),
]);
const ccbuddyWorkspaceModelToolSchema = z
  .object({
    name: nonEmptyString,
    description: z.string().optional(),
    inputSchema: z.record(z.string(), z.unknown()),
  })
  .strict();

export const ccbuddyWorkspaceGenerateTextParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    selection: modelSelectionSchema,
    prompt: nonEmptyString.optional(),
    messages: z.array(ccbuddyWorkspaceModelMessageSchema).min(1).optional(),
    tools: z.array(ccbuddyWorkspaceModelToolSchema).optional(),
    querySource: nonEmptyString,
    maxOutputTokens: z.number().int().positive().optional(),
    operationId: nonEmptyString.optional(),
  })
  .strict()
  .refine((value) => value.prompt !== undefined || value.messages !== undefined, {
    message: "prompt 或 messages 至少需要提供一个",
  });
export const ccbuddyWorkspaceGenerateTextResultSchema = z
  .object({
    text: z.string(),
    selection: modelSelectionSchema,
    toolCalls: z.array(ccbuddyWorkspaceModelToolCallSchema).optional(),
    // 可选以兼容仍在运行的旧 app-server；新 CLI 始终返回结构化结束原因。
    finishReason: z.string().optional(),
    usage: z
      .object({
        inputTokens: z.number().nonnegative().optional(),
        outputTokens: z.number().nonnegative().optional(),
        totalTokens: z.number().nonnegative().optional(),
        cacheReadTokens: z.number().nonnegative().optional(),
        cacheWriteTokens: z.number().nonnegative().optional(),
        reasoningTokens: z.number().nonnegative().optional(),
        serverToolUse: z
          .object({
            webSearchRequests: z.number().nonnegative().optional(),
            webFetchRequests: z.number().nonnegative().optional(),
          })
          .strict()
          .optional(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddyWorkspaceGenerateTextParams = z.infer<
  typeof ccbuddyWorkspaceGenerateTextParamsSchema
>;
export type CCbuddyWorkspaceModelMessage = z.infer<typeof ccbuddyWorkspaceModelMessageSchema>;
export type CCbuddyWorkspaceModelTool = z.infer<typeof ccbuddyWorkspaceModelToolSchema>;
export type CCbuddyWorkspaceGenerateTextResult = z.infer<
  typeof ccbuddyWorkspaceGenerateTextResultSchema
>;
export const ccbuddyWorkspaceCancelGenerateTextParamsSchema = z
  .object({ operationId: nonEmptyString })
  .strict();
export const ccbuddyWorkspaceCancelGenerateTextResultSchema = z
  .object({ operationId: nonEmptyString, cancelled: z.boolean() })
  .strict();

export const ccbuddyProviderTestModelConnectivityParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    selection: modelSelectionSchema,
  })
  .strict();
export const ccbuddyProviderTestModelConnectivityResultSchema = z
  .object({ success: z.literal(true) })
  .strict();
export type CCbuddyProviderTestModelConnectivityParams = z.infer<
  typeof ccbuddyProviderTestModelConnectivityParamsSchema
>;
export type CCbuddyProviderTestModelConnectivityResult = z.infer<
  typeof ccbuddyProviderTestModelConnectivityResultSchema
>;

export const ccbuddyProviderUpdateAccountConfigParamsSchema = z
  .object({
    revision: nonEmptyString,
    basedOnCCbuddyBuiltinRevision: nonEmptyString,
    // Provider Config 的字段校验由 @ccbuddy/provider 负责；协议层只约束可传输信封。
    providers: z.record(z.string(), z.unknown()),
    // 账号状态与 Overlay 必须一起传递，否则 Worker 会丢失非当前套餐的执行门禁。
    states: z.record(
      z.string(),
      z
        .object({
          availability: z.enum(["available", "pending", "unavailable", "unknown"]),
          entitled: z.boolean(),
          unavailableReason: accountProviderUnavailableReasonSchema.optional(),
          current: z.boolean().optional(),
          connectionKey: z.string().optional(),
          effectiveAt: z.number().finite().optional(),
        })
        .strict(),
    ),
  })
  .strict();
export const ccbuddyProviderUpdateAccountConfigResultSchema = z
  .object({
    // 收到账号结果不代表配套 Built-in 已到达；应用版本只能读取 Registry 快照。
    receivedRevision: nonEmptyString,
    providerCount: z.number().int().nonnegative(),
    status: z.enum(["received", "unchanged"]),
  })
  .strict();
export type CCbuddyProviderUpdateAccountConfigResult = z.infer<
  typeof ccbuddyProviderUpdateAccountConfigResultSchema
>;
export const ccbuddyInteractionPreferencesSchema = z
  .object({
    askUserQuestionAutoResolutionEnabled: z.boolean(),
  })
  .strict();
export type CCbuddyInteractionPreferences = z.infer<typeof ccbuddyInteractionPreferencesSchema>;

export const ccbuddyWorkspaceUpdateInteractionPreferencesParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    preferences: ccbuddyInteractionPreferencesSchema,
  })
  .strict();
export type CCbuddyWorkspaceUpdateInteractionPreferencesParams = z.infer<
  typeof ccbuddyWorkspaceUpdateInteractionPreferencesParamsSchema
>;

export const ccbuddyWorkspaceUpdateInteractionPreferencesResultSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    askUserQuestionAutoResolutionEnabled: z.boolean(),
    snoozedInteractionCount: z.number().int().nonnegative(),
  })
  .strict();
export type CCbuddyWorkspaceUpdateInteractionPreferencesResult = z.infer<
  typeof ccbuddyWorkspaceUpdateInteractionPreferencesResultSchema
>;

export const ccbuddyModelIoPreferencesSchema = z
  .object({
    fullRetentionEnabled: z.boolean(),
  })
  .strict();
export type CCbuddyModelIoPreferences = z.infer<typeof ccbuddyModelIoPreferencesSchema>;

export const ccbuddyWorkspaceUpdateModelIoPreferencesParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    preferences: ccbuddyModelIoPreferencesSchema,
  })
  .strict();
export type CCbuddyWorkspaceUpdateModelIoPreferencesParams = z.infer<
  typeof ccbuddyWorkspaceUpdateModelIoPreferencesParamsSchema
>;

export const ccbuddyWorkspaceUpdateModelIoPreferencesResultSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    fullRetentionEnabled: z.boolean(),
    updatedSessionCount: z.number().int().nonnegative(),
  })
  .strict();
export type CCbuddyWorkspaceUpdateModelIoPreferencesResult = z.infer<
  typeof ccbuddyWorkspaceUpdateModelIoPreferencesResultSchema
>;

export const ccbuddyWorkspaceUpdateOffPeakToolPolicyParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    enabled: z.boolean(),
  })
  .strict();
export type CCbuddyWorkspaceUpdateOffPeakToolPolicyParams = z.infer<
  typeof ccbuddyWorkspaceUpdateOffPeakToolPolicyParamsSchema
>;

export const ccbuddyWorkspaceUpdateOffPeakToolPolicyResultSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    enabled: z.boolean(),
  })
  .strict();
export type CCbuddyWorkspaceUpdateOffPeakToolPolicyResult = z.infer<
  typeof ccbuddyWorkspaceUpdateOffPeakToolPolicyResultSchema
>;

// 动态工作流灰度门禁：workspace 级事实，
// 与 Off-Peak 同一套 host→CLI 同步模式；旧 CLI method-not-found → host 降级忽略。
export const ccbuddyWorkspaceUpdateDynamicWorkflowPolicyParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    enabled: z.boolean(),
  })
  .strict();
export type CCbuddyWorkspaceUpdateDynamicWorkflowPolicyParams = z.infer<
  typeof ccbuddyWorkspaceUpdateDynamicWorkflowPolicyParamsSchema
>;

export const ccbuddyWorkspaceUpdateDynamicWorkflowPolicyResultSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    enabled: z.boolean(),
  })
  .strict();
export type CCbuddyWorkspaceUpdateDynamicWorkflowPolicyResult = z.infer<
  typeof ccbuddyWorkspaceUpdateDynamicWorkflowPolicyResultSchema
>;

export const ccbuddyPermissionRequestParamsSchema = z
  .object({
    requestId: nonEmptyString,
    sessionId: nonEmptyString,
    turnId: nonEmptyString.optional(),
    toolCallId: nonEmptyString,
    toolName: nonEmptyString,
    reason: z.string(),
    riskLevel: z.enum(["low", "medium", "high", "critical"]),
    input: z.unknown(),
    origin: ccbuddyInteractionRequestOriginSchema.optional(),
    options: z.array(ccbuddyPermissionOptionSchema).min(1),
  })
  .strict();
export type CCbuddyPermissionRequestParams = z.infer<typeof ccbuddyPermissionRequestParamsSchema>;

/** Agent 请求 app 枚举当前 workspace/session 可达且已完成握手的 browser backend。 */
export const ccbuddyBrowserListParamsSchema = z
  .object({
    requestId: nonEmptyString,
    sessionId: nonEmptyString,
    turnId: nonEmptyString.optional(),
    workspaceKey: nonEmptyString,
    workspacePath: nonEmptyString,
    workspaceIdentity: nonEmptyString.optional(),
    remoteSessionId: nonEmptyString.optional(),
    clientMode: browserClientModeSchema,
    sessionContext: browserSessionContextKindSchema,
  })
  .strict();
export type CCbuddyBrowserListParams = z.infer<typeof ccbuddyBrowserListParamsSchema>;

export const ccbuddyBrowserListResultSchema = browserBackendListResultSchema;
export type CCbuddyBrowserListResult = z.infer<typeof ccbuddyBrowserListResultSchema>;

/** Agent 把一条 browser-use 命令发送给 app 执行。 */
export const ccbuddyBrowserExecuteParamsSchema = z
  .object({
    requestId: nonEmptyString,
    sessionId: nonEmptyString,
    turnId: nonEmptyString.optional(),
    browserId: nonEmptyString.optional(),
    browserGeneration: z.number().int().nonnegative().optional(),
    workspaceKey: nonEmptyString.optional(),
    workspacePath: nonEmptyString.optional(),
    workspaceIdentity: nonEmptyString.optional(),
    remoteSessionId: nonEmptyString.optional(),
    clientMode: browserClientModeSchema.optional(),
    sessionContext: browserSessionContextKindSchema.optional(),
    command: browserCommandSchema,
  })
  .strict();
export type CCbuddyBrowserExecuteParams = z.infer<typeof ccbuddyBrowserExecuteParamsSchema>;

// browser command result 是 app/agent 的同源协议结果；其中 duplicate_request_id 用于在真正维护
// pending/running 生命周期的边界拒绝 correlation key 冲突，不能依赖上游 UUID 概率保证。
export const ccbuddyBrowserExecuteResultSchema = browserCommandResultSchema;
export type CCbuddyBrowserExecuteResult = z.infer<typeof ccbuddyBrowserExecuteResultSchema>;

export const ccbuddyUserInputOptionSchema = z
  .object({
    value: nonEmptyString,
    label: nonEmptyString,
    description: z.string().optional(),
    preview: z.string().optional(),
  })
  .strict();
export const ccbuddyUserInputQuestionSchema = z
  .object({
    question: nonEmptyString,
    header: nonEmptyString,
    options: z.array(ccbuddyUserInputOptionSchema).min(1),
    multiSelect: z.boolean().optional(),
  })
  .strict();
export type CCbuddyUserInputQuestion = z.infer<typeof ccbuddyUserInputQuestionSchema>;

export const ccbuddyUserInputRequestParamsSchema = z
  .object({
    requestId: nonEmptyString,
    sessionId: nonEmptyString,
    turnId: nonEmptyString.optional(),
    toolCallId: nonEmptyString.optional(),
    toolName: nonEmptyString.optional(),
    prompt: z.string().optional(),
    questions: z.array(ccbuddyUserInputQuestionSchema).min(1).optional(),
    input: z.unknown().optional(),
    origin: ccbuddyInteractionRequestOriginSchema.optional(),
    schema: z.unknown().optional(),
  })
  .strict();
export type CCbuddyUserInputRequestParams = z.infer<typeof ccbuddyUserInputRequestParamsSchema>;

export const ccbuddyUserInputResponseSchema = z
  .object({
    action: z.enum(["accept", "decline", "cancel"]),
    content: jsonObjectSchema.optional(),
    reason: z.string().optional(),
  })
  .strict();
export type CCbuddyUserInputResponse = z.infer<typeof ccbuddyUserInputResponseSchema>;

export const ccbuddyProviderRuntimeHeadersRequestReasonSchema = z.enum(["model-request"]);
export const ccbuddyProviderRuntimeHeadersRequestParamsSchema = z
  .object({
    requestId: nonEmptyString,
    sessionId: nonEmptyString,
    turnId: nonEmptyString.optional(),
    workspace: ccbuddyWorkspaceRefSchema,
    modelSelection: modelSelectionSchema,
    providerId: nonEmptyString,
    accountAccess: ccbuddyProviderAccountAccessSchema.optional(),
    reason: ccbuddyProviderRuntimeHeadersRequestReasonSchema,
  })
  .strict();
export type CCbuddyProviderRuntimeHeadersRequestParams = z.infer<
  typeof ccbuddyProviderRuntimeHeadersRequestParamsSchema
>;

/** 请求取消只作用于同 workspace/session 的这一轮凭据刷新。 */
export const ccbuddyProviderRuntimeHeadersCancelledSchema = z
  .object({
    requestId: nonEmptyString,
    sessionId: nonEmptyString,
    workspace: ccbuddyWorkspaceRefSchema,
  })
  .strict();
export type CCbuddyProviderRuntimeHeadersCancelled = z.infer<
  typeof ccbuddyProviderRuntimeHeadersCancelledSchema
>;

export const ccbuddyProviderRuntimeHeadersResponseSchema = z.discriminatedUnion("headersApplied", [
  z
    .object({
      headersApplied: z.literal(true),
      // 合并重接：成功必须携带当前请求的鉴权材料，不依赖旧 Registry 已被写入。
      requestAuth: z
        .object({
          apiKey: nonEmptyString.optional(),
          headers: z.record(nonEmptyString, nonEmptyString).optional(),
        })
        .strict(),
      errorMessage: nonEmptyString.optional(),
    })
    .strict(),
  z
    .object({
      headersApplied: z.literal(false),
      errorMessage: nonEmptyString.optional(),
    })
    .strict(),
]);
export type CCbuddyProviderRuntimeHeadersResponse = z.infer<
  typeof ccbuddyProviderRuntimeHeadersResponseSchema
>;

// ── 官方 Server MCP 鉴权──
// Agent 进程不是用户身份权威：它把 (pluginId, mcpKey, targetOrigin) 报给 host，由 host
// 解析当前 Coding Plan 凭证并回传本次请求的身份头。请求侧不含任何秘密。
// 与 interaction/requestProviderRuntimeHeaders 同类：Agent 发起、host 自动响应、零 UI。
export const ccbuddyOfficialMcpAuthHeadersRequestParamsSchema = z
  .object({
    requestId: nonEmptyString,
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString,
    mcpKey: nonEmptyString,
    targetOrigin: nonEmptyString,
  })
  .strict();
export type CCbuddyOfficialMcpAuthHeadersRequestParams = z.infer<
  typeof ccbuddyOfficialMcpAuthHeadersRequestParamsSchema
>;

/**
 * 失败原因必须可枚举，避免调用方按文本分流；因此响应不含 errorMessage。
 *
 * `official_mcp_origin_untrusted` 是 host 侧二次校验的拒绝原因：`targetOrigin` 不等于当前
 * CCbuddy API origin。判定只看 origin，`pluginId` / `mcpKey` 仅用于日志归属。与"未登录/无凭据"
 * 分开，才能在排查时区分"被拒绝"和"没身份"。
 */
export const ccbuddyOfficialMcpAuthFailureReasonSchema = z.enum(
  OFFICIAL_MCP_AUTH_PORT_FAILURE_REASONS,
);

export const ccbuddyOfficialMcpAuthHeadersResponseSchema = z.discriminatedUnion("ok", [
  z
    .object({
      ok: z.literal(true),
      headers: z.record(z.string(), z.string()),
    })
    .strict(),
  z
    .object({
      ok: z.literal(false),
      reason: ccbuddyOfficialMcpAuthFailureReasonSchema,
    })
    .strict(),
]);
export type CCbuddyOfficialMcpAuthHeadersResponse = z.infer<
  typeof ccbuddyOfficialMcpAuthHeadersResponseSchema
>;

// ── Plugin management (list + enable/disable) ──
// 镜像 @ccbuddy/contracts 的 PluginMetadata, 仅保留 UI 需要的可序列化字段。
export const ccbuddyPluginOptionValueSchema = z.union([z.string(), z.number(), z.boolean()]);
export type CCbuddyPluginOptionValue = z.infer<typeof ccbuddyPluginOptionValueSchema>;
export const ccbuddyPluginScopeSchema = z.enum(["user", "workspace"]);
export type CCbuddyPluginScope = z.infer<typeof ccbuddyPluginScopeSchema>;
export const ccbuddyPluginHookDetailSchema = z
  .object({
    event: nonEmptyString,
    matcher: z.string().optional(),
    type: z.enum(["command", "process"]),
    command: nonEmptyString,
    args: z.array(z.string()).optional(),
    async: z.boolean().optional(),
    shell: z.union([z.literal(true), z.string()]).optional(),
    timeout: z.number().positive().optional(),
    timeoutMs: z.number().int().positive().optional(),
    statusMessage: z.string().optional(),
    sourcePath: z.string(),
    runnable: z.boolean(),
  })
  .strict();
export const ccbuddyPluginUserConfigOptionSchema = z
  .object({
    default: ccbuddyPluginOptionValueSchema.optional(),
    description: z.string().optional(),
    required: z.boolean().optional(),
    sensitive: z.boolean().optional(),
    title: z.string().optional(),
    type: z.enum(["string", "number", "boolean", "directory", "file"]).optional(),
  })
  .strict();
export type CCbuddyPluginUserConfigOption = z.infer<typeof ccbuddyPluginUserConfigOptionSchema>;

// 组件类型与详情弹窗/市场详情共用的分组顺序保持一致：agent / command / skill / hook / mcp。
// 注意：这三个 schema 必须定义在 ccbuddyPluginInfoSchema 之前，因为后者（.strict()）的 components 字段引用了它们。
export const ccbuddyPluginComponentKindSchema = z.enum([
  "agent",
  "command",
  "skill",
  "hook",
  "mcp",
]);
export type CCbuddyPluginComponentKind = z.infer<typeof ccbuddyPluginComponentKindSchema>;

export const ccbuddyPluginComponentItemSchema = z
  .object({
    name: nonEmptyString,
    // 描述来自组件 frontmatter（SKILL.md / command / agent）或 manifest；缺失时省略，不伪造。
    description: z.string().optional(),
  })
  .strict();
export const ccbuddyPluginComponentGroupSchema = z
  .object({
    kind: ccbuddyPluginComponentKindSchema,
    items: z.array(ccbuddyPluginComponentItemSchema),
  })
  .strict();
export type CCbuddyPluginComponentGroup = z.infer<typeof ccbuddyPluginComponentGroupSchema>;

export const ccbuddyPluginInfoSchema = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    description: z.string().optional(),
    version: z.string().optional(),
    enabled: z.boolean(),
    source: nonEmptyString,
    marketplace: nonEmptyString,
    // manifest（plugin.json）的作者/主页回退字段；商店 listing 缺失时详情页信息区用它兜底。
    author: z.string().optional(),
    authorUrl: z.string().optional(),
    homepage: z.string().optional(),
    skillCount: z.number().int().nonnegative().optional(),
    skillRootCount: z.number().int().nonnegative(),
    commandRootCount: z.number().int().nonnegative(),
    // 权威组件清单（名称 + 可选描述），由 CLI 对插件根目录枚举得出，与启用态无关。
    // 详情 UI 直接展示，取代旧的「数量取协议、名称靠 UI 侧 join」脆弱方案。optional 兼容旧 payload。
    components: z.array(ccbuddyPluginComponentGroupSchema).optional(),
    declaredMcpServerNames: z.array(z.string()).optional(),
    hostMcpServerNames: z.array(z.string()).optional(),
    mcpServerNames: z.array(z.string()),
    hookDetails: z.array(ccbuddyPluginHookDetailSchema).optional(),
    rootPath: z.string(),
    userConfig: z.record(z.string(), ccbuddyPluginUserConfigOptionSchema).optional(),
    configuredOptions: z.record(z.string(), ccbuddyPluginOptionValueSchema).optional(),
    // 缺省表示 package 可用；missing 用于保留已声明但目标 Host 尚未物化的配置行。
    packageStatus: z.literal("missing").optional(),
    rootSource: ccbuddyPluginScopeSchema.optional(),
    enabledSource: ccbuddyPluginScopeSchema.optional(),
    optionSources: z.record(z.string(), ccbuddyPluginScopeSchema).optional(),
  })
  .strict();
export type CCbuddyPluginInfo = z.infer<typeof ccbuddyPluginInfoSchema>;

export const ccbuddyPluginDiagnosticSchema = z
  .object({
    code: z.string(),
    message: z.string(),
    severity: z.enum(["warning", "error"]).optional(),
    pluginId: z.string().optional(),
  })
  .strict();
export type CCbuddyPluginDiagnostic = z.infer<typeof ccbuddyPluginDiagnosticSchema>;

export const ccbuddyPluginsListParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    configScope: ccbuddyPluginScopeSchema.optional(),
  })
  .strict();
export const ccbuddyPluginsListResultSchema = z
  .object({
    plugins: z.array(ccbuddyPluginInfoSchema),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
  })
  .strict();
export type CCbuddyPluginsListResult = z.infer<typeof ccbuddyPluginsListResultSchema>;

// ── Plugin 对话引用 catalog──
// Session-scoped 只读投影：带 sessionId → 该 Session 创建时冻结的身份 catalog；
// 不带 → workspace 当前 catalog（新建草稿 Picker）。身份与能力字段保持
// identifiers-only，不携带 rootPath/配置等；可选 icon/displayName(I18n)/description(I18n)
// 仅供 UI 展示与 Picker 搜索，不参与身份、权限或 runtime reminder。
export const ccbuddyPluginReferenceCatalogEntrySchema = z
  .object({
    // 仅 referenceCatalogWithCategory 返回；旧入口保持原结构。
    category: nonEmptyString.optional(),
    pluginId: nonEmptyString,
    name: nonEmptyString,
    marketplace: nonEmptyString,
    icon: z.string().optional(),
    // 商店 listing 的 display-only 本地化显示名投影（沿 icon 先例）：让 Picker 能按
    // 中文显示名搜索/展示；locale 解析复用 shared 的 plugin-display-name helper。
    displayName: z.string().optional(),
    displayNameI18n: z.record(z.string(), z.string()).optional(),
    // 仅供 Picker 展示，不进入能力身份或 model-only reminder。
    description: z.string().optional(),
    descriptionI18n: z.record(z.string(), z.string()).optional(),
    enabled: z.boolean(),
    // 非空 = 与其他 enabled Plugin 共享 manifest name 的 V1 fail closed 冲突：
    // Picker 禁选并展示原因，runtime 解析按 ambiguous 跳过。
    conflictingPluginIds: z.array(nonEmptyString),
    skillQualifiedNames: z.array(nonEmptyString),
    mcpServerNames: z.array(nonEmptyString),
    // 旧 Host 不投影该字段时按空数组兼容；只有新 Agent 会把它用于 reminder live 交集。
    subagentNames: z.array(nonEmptyString).default([]),
  })
  .strict();
export type CCbuddyPluginReferenceCatalogEntry = z.infer<
  typeof ccbuddyPluginReferenceCatalogEntrySchema
>;

export const ccbuddyPluginsReferenceCatalogParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    // 已有 Session 的 Picker 必须带 sessionId 才能拿到 session-owned catalog；
    // session 不存在时按协议错误 fail closed，禁止静默回退 workspace authority。
    sessionId: nonEmptyString.optional(),
  })
  .strict();
export type CCbuddyPluginsReferenceCatalogParams = z.infer<
  typeof ccbuddyPluginsReferenceCatalogParamsSchema
>;
export const ccbuddyPluginsReferenceCatalogResultSchema = z
  .object({
    authority: z.enum(["session", "workspace"]),
    plugins: z.array(ccbuddyPluginReferenceCatalogEntrySchema),
  })
  .strict();
export type CCbuddyPluginsReferenceCatalogResult = z.infer<
  typeof ccbuddyPluginsReferenceCatalogResultSchema
>;

// ── Skill 对话引用 catalog──
// 新草稿读取 workspace 当前目录；已有 Session 读取 AgentRuntime 首次 context
// 初始化时冻结的发现结果。该协议只承载 Composer 的只读引用投影，不替代 Settings
// 的 Skill 管理接口，也不持久化 runtime 快照。
export const ccbuddySkillReferenceCatalogEntrySchema = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    description: z.string(),
    path: nonEmptyString,
    scope: z.enum(["workspace", "user", "plugin"]),
    enabled: z.literal(true),
    pluginName: nonEmptyString.optional(),
  })
  .strict();
export type CCbuddySkillReferenceCatalogEntry = z.infer<
  typeof ccbuddySkillReferenceCatalogEntrySchema
>;

export const ccbuddySkillsReferenceCatalogParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    // 带 sessionId 时必须命中该进程内的 resident Session；未知 Session fail closed，
    // 禁止回退到 workspace 当前目录而把新 Skill 泄漏进旧对话。
    sessionId: nonEmptyString.optional(),
  })
  .strict();
export type CCbuddySkillsReferenceCatalogParams = z.infer<
  typeof ccbuddySkillsReferenceCatalogParamsSchema
>;
export const ccbuddySkillsReferenceCatalogResultSchema = z
  .object({
    authority: z.enum(["session", "workspace"]),
    skills: z.array(ccbuddySkillReferenceCatalogEntrySchema),
  })
  .strict();
export type CCbuddySkillsReferenceCatalogResult = z.infer<
  typeof ccbuddySkillsReferenceCatalogResultSchema
>;

// ── 已保存工作流的 GUI 中枢──
// workspace 级、无会话的五个方法，照 skills/referenceCatalog 的先例：每次调用现扫
// `<cwd>/.ccbuddy/workflows/`（挂载时快照会漏掉手改的文件）。形状与 @ccbuddy/contracts 的
// saved-workflow.ts 逐字对齐——依赖方向是 contracts → shared，所以这里结构化地再声明一遍，
// 而不是 import；两边的 strict 形状由 bootstrap 侧的协议测试互相钉住。
export const ccbuddySavedWorkflowArgTypeSchema = z.enum(["string", "number", "boolean", "json"]);
export type CCbuddySavedWorkflowArgType = z.infer<typeof ccbuddySavedWorkflowArgTypeSchema>;
export const ccbuddySavedWorkflowArgDeclarationSchema = z
  .object({
    type: ccbuddySavedWorkflowArgTypeSchema,
    description: z.string().optional(),
    required: z.boolean().optional(),
    default: z.unknown().optional(),
  })
  .strict();
export type CCbuddySavedWorkflowArgDeclaration = z.infer<
  typeof ccbuddySavedWorkflowArgDeclarationSchema
>;
export const ccbuddySavedWorkflowArgsDeclarationSchema = z.record(
  z.string(),
  ccbuddySavedWorkflowArgDeclarationSchema,
);
export type CCbuddySavedWorkflowArgsDeclaration = z.infer<
  typeof ccbuddySavedWorkflowArgsDeclarationSchema
>;
export const ccbuddySavedWorkflowMetaSchema = z
  .object({
    description: nonEmptyString,
    whenToUse: nonEmptyString.optional(),
    args: ccbuddySavedWorkflowArgsDeclarationSchema.optional(),
  })
  .strict();
export type CCbuddySavedWorkflowMeta = z.infer<typeof ccbuddySavedWorkflowMetaSchema>;
// 作用域两档：项目档落 `<cwd>/.ccbuddy/workflows/`、全局档落 agent 机器的 `~/.ccbuddy/workflows/`。作用域由文件所在目录推得，frontmatter 不存 scope。
export const ccbuddySavedWorkflowScopeSchema = z.enum(["project", "global"]);
export type CCbuddySavedWorkflowScope = z.infer<typeof ccbuddySavedWorkflowScopeSchema>;
export const ccbuddySavedWorkflowEntrySchema = z
  .object({
    name: nonEmptyString,
    description: z.string(),
    whenToUse: z.string().optional(),
    args: ccbuddySavedWorkflowArgsDeclarationSchema.optional(),
    scope: ccbuddySavedWorkflowScopeSchema,
    path: nonEmptyString,
  })
  .strict();
export type CCbuddySavedWorkflowEntry = z.infer<typeof ccbuddySavedWorkflowEntrySchema>;
export const ccbuddySavedWorkflowInvalidEntrySchema = z
  .object({ path: nonEmptyString, reason: nonEmptyString })
  .strict();
export type CCbuddySavedWorkflowInvalidEntry = z.infer<
  typeof ccbuddySavedWorkflowInvalidEntrySchema
>;
/** 名字非法 / 未找到 / frontmatter 坏 / 读错——与 core store 的 resolve 失败四态逐字对应。 */
export const ccbuddySavedWorkflowFailureReasonSchema = z.enum([
  "invalid_name",
  "not_found",
  "parse_error",
  "read_error",
]);
export type CCbuddySavedWorkflowFailureReason = z.infer<
  typeof ccbuddySavedWorkflowFailureReasonSchema
>;
const ccbuddySavedWorkflowFailureSchema = z
  .object({
    ok: z.literal(false),
    reason: ccbuddySavedWorkflowFailureReasonSchema,
    detail: z.string().optional(),
  })
  .strict();

export const ccbuddyWorkflowsListParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    // 缺省即 `project`（本项目档）。给 `global` 时改扫本机 `~/.ccbuddy/workflows/`；此时 `workspace`
    // 仍必填，但只是**载体运行时**——协议处理器对全局档不读它的路径。
    scope: ccbuddySavedWorkflowScopeSchema.optional(),
  })
  .strict();
export type CCbuddyWorkflowsListParams = z.infer<typeof ccbuddyWorkflowsListParamsSchema>;
export const ccbuddyWorkflowsListResultSchema = z
  .object({
    workflows: z.array(ccbuddySavedWorkflowEntrySchema),
    invalid: z.array(ccbuddySavedWorkflowInvalidEntrySchema),
    // 扫过的目录（本地绝对路径），即使目录还不存在也回：GUI 的文件监听靠它 watch。
    dir: nonEmptyString,
  })
  .strict();
export type CCbuddyWorkflowsListResult = z.infer<typeof ccbuddyWorkflowsListResultSchema>;

export const ccbuddyWorkflowsGetParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    name: nonEmptyString,
    // 缺省 `project`；`global` 时只查本机全局根。`workspace` 语义同 list（全局档只当载体）。
    scope: ccbuddySavedWorkflowScopeSchema.optional(),
  })
  .strict();
export type CCbuddyWorkflowsGetParams = z.infer<typeof ccbuddyWorkflowsGetParamsSchema>;
export const ccbuddyWorkflowsGetResultSchema = z.union([
  z
    .object({
      ok: z.literal(true),
      name: nonEmptyString,
      path: nonEmptyString,
      scope: ccbuddySavedWorkflowScopeSchema,
      meta: ccbuddySavedWorkflowMetaSchema,
      /** 脚本本体（frontmatter 之后逐字节），即被类型检查与执行的那一份。 */
      script: z.string(),
    })
    .strict(),
  ccbuddySavedWorkflowFailureSchema,
]);
export type CCbuddyWorkflowsGetResult = z.infer<typeof ccbuddyWorkflowsGetResultSchema>;

export const ccbuddyWorkflowsUpdateMetaParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    name: nonEmptyString,
    meta: ccbuddySavedWorkflowMetaSchema,
    // 缺省 `project`；`global` 时只写本机全局根那一份。`workspace` 语义同 list。
    scope: ccbuddySavedWorkflowScopeSchema.optional(),
  })
  .strict();
export type CCbuddyWorkflowsUpdateMetaParams = z.infer<
  typeof ccbuddyWorkflowsUpdateMetaParamsSchema
>;
export const ccbuddyWorkflowsUpdateMetaResultSchema = z.union([
  z.object({ ok: z.literal(true), path: nonEmptyString }).strict(),
  ccbuddySavedWorkflowFailureSchema,
]);
export type CCbuddyWorkflowsUpdateMetaResult = z.infer<
  typeof ccbuddyWorkflowsUpdateMetaResultSchema
>;

export const ccbuddyWorkflowsDeleteParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    name: nonEmptyString,
    // 缺省 `project`；`global` 时按 scope 选根删除（不再写死 roots[0]）。`workspace` 语义同 list。
    scope: ccbuddySavedWorkflowScopeSchema.optional(),
  })
  .strict();
export type CCbuddyWorkflowsDeleteParams = z.infer<typeof ccbuddyWorkflowsDeleteParamsSchema>;
export const ccbuddyWorkflowsDeleteResultSchema = z.union([
  z.object({ ok: z.literal(true), path: nonEmptyString }).strict(),
  ccbuddySavedWorkflowFailureSchema,
]);
export type CCbuddyWorkflowsDeleteResult = z.infer<typeof ccbuddyWorkflowsDeleteResultSchema>;

export const CCBUDDY_WORKFLOWS_RUNS_MAX_LIMIT = 50;
export const ccbuddyWorkflowsRunsParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    /** 只要这个名字的 run（`dwf_run.name` 字面等值）；缺省即本项目全部 run。 */
    name: nonEmptyString.optional(),
    limit: z.number().int().min(1).max(CCBUDDY_WORKFLOWS_RUNS_MAX_LIMIT),
    // 缺省 `project`：只查 `dwf_run.cwd === workspacePath` 的 run。`global` 时**不**按 cwd 过滤，
    // 跨所有项目取该名字的运行历史（全局工作流在任何项目里跑，历史因此跨 cwd）；结果行带 `cwd`
    // 供 GUI 标项目。`workspace` 语义同 list（全局档只当载体）。
    scope: ccbuddySavedWorkflowScopeSchema.optional(),
  })
  .strict();
export type CCbuddyWorkflowsRunsParams = z.infer<typeof ccbuddyWorkflowsRunsParamsSchema>;
// 三终态词汇：errored = 脚本之错，stopped = 被停下（可恢复）。
export const ccbuddySavedWorkflowRunStatusSchema = z.enum([
  "pending",
  "running",
  "completed",
  "errored",
  "stopped",
]);
export type CCbuddySavedWorkflowRunStatus = z.infer<typeof ccbuddySavedWorkflowRunStatusSchema>;
export const ccbuddySavedWorkflowRunStopReasonSchema = z.enum([
  "user",
  "model",
  "provider",
  "interrupted",
  "superseded",
]);
export const ccbuddySavedWorkflowRunSchema = z
  .object({
    runId: nonEmptyString,
    name: z.string().optional(),
    status: ccbuddySavedWorkflowRunStatusSchema,
    // `status === "stopped"` 才在场。
    stopReason: ccbuddySavedWorkflowRunStopReasonSchema.optional(),
    createdAt: z.number(),
    updatedAt: z.number(),
    spentTokens: z.number(),
    /** 发起它的会话与 CreateWorkflow 工具调用：有这两个才能从中枢打开实例详情。老行可缺。 */
    parentSessionId: z.string().optional(),
    toolCallId: z.string().optional(),
    args: z.record(z.string(), z.unknown()).optional(),
    // 实际运行的项目目录（`dwf_run.cwd`）。全局档的 `workflows/runs` 跨 cwd 查询，GUI 用它给
    // 每行标项目；项目档变体里它恒等于 workspacePath，GUI 可忽略。老行可缺。
    cwd: z.string().optional(),
    // 这次运行发布的**用户面产物**：中枢的运行历史行在
    // 状态词之后画一串 kind chips，详情页头部的「最近产物」条取最近一次 completed run 的这一份。
    // ⚠ 术语：这里的 artifact 是脚本经 `artifact.*` 发布给用户看的产出，不是脚本的顶层返回值。
    // 只带 chip 画得下的字段（≤ 8 件，取最新版的元数据）；字节与条目经 v4 查询按需读。
    // optional，照上面 `cwd` 的先例：老 CLI 不发，少一个键是退化不是错误。
    artifacts: z
      .array(
        z
          .object({
            id: nonEmptyString,
            kind: z.enum(["file", "markdown", "chart", "table", "metrics", "board"]),
            title: z.string().optional(),
            version: z.number(),
            contentType: z.string().optional(),
          })
          .strict(),
      )
      .max(8)
      .optional(),
  })
  .strict();
export type CCbuddySavedWorkflowRun = z.infer<typeof ccbuddySavedWorkflowRunSchema>;
export const ccbuddyWorkflowsRunsResultSchema = z
  .object({
    runs: z.array(ccbuddySavedWorkflowRunSchema),
    /** 为真时才在场：还有更多 run 没进这一页（多取一条判定，不是 length === limit）。 */
    truncated: z.literal(true).optional(),
  })
  .strict();
export type CCbuddyWorkflowsRunsResult = z.infer<typeof ccbuddyWorkflowsRunsResultSchema>;

// workflows/move：把本机全局根的同名文件搬到 `workspace` 项目根。**只此一向**：项目→全局不是搬文件而是模型的概括（「提升为
// 全局」在该项目开新会话、经 SaveWorkflow 另存），所以没有 `to` 参数。同机同用户，rename 优先、EXDEV
// 回落 copy+unlink；逐字节搬，不改内容（frontmatter 不存 scope）；`move` 不覆盖——目标已存在即拒绝
// （覆盖是 SaveWorkflow 经确认窗才有的动作，不变式 7）。`workspace` 既是载体运行时也是目标项目。
export const ccbuddyWorkflowsMoveParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    name: nonEmptyString,
  })
  .strict();
export type CCbuddyWorkflowsMoveParams = z.infer<typeof ccbuddyWorkflowsMoveParamsSchema>;
export const ccbuddyWorkflowsMoveResultSchema = z.union([
  z
    .object({
      ok: z.literal(true),
      /** 源落点路径（全局根，搬走前）。 */
      from: nonEmptyString,
      /** 目标落点路径（项目根，搬到处）。 */
      to: nonEmptyString,
    })
    .strict(),
  z
    .object({
      ok: z.literal(false),
      // target_exists：目标档已有同名（move 不覆盖）；not_found：源档没有这个名字；
      // read_error / write_error：搬运时的 I/O 失败；invalid_name：名字先验没过。
      reason: z.enum(["invalid_name", "not_found", "target_exists", "read_error", "write_error"]),
      path: z.string().optional(),
      detail: z.string().optional(),
    })
    .strict(),
]);
export type CCbuddyWorkflowsMoveResult = z.infer<typeof ccbuddyWorkflowsMoveResultSchema>;

// 推荐 Prompt 的可信插件解析：UI 不拆解 stableId，也不从旧目录快照推断可安装性。
export const ccbuddyPluginSuggestedReferenceStatusSchema = z.enum([
  "ready",
  "disabled",
  "missing",
  "conflict",
  "unavailable",
]);
export type CCbuddyPluginSuggestedReferenceStatus = z.infer<
  typeof ccbuddyPluginSuggestedReferenceStatusSchema
>;
export const ccbuddyPluginOperationStateSchema = z.enum([
  "checking",
  "refreshing",
  "installing",
  "enabling",
  "cancelling",
  "cancelled",
  "complete",
  "failed",
]);
export type CCbuddyPluginOperationState = z.infer<typeof ccbuddyPluginOperationStateSchema>;
export const ccbuddyPluginOperationProgressNotificationSchema = z
  .object({
    operationId: nonEmptyString,
    state: z.literal("refreshing"),
  })
  .strict();
export type CCbuddyPluginOperationProgressNotification = z.infer<
  typeof ccbuddyPluginOperationProgressNotificationSchema
>;
export const ccbuddyPluginsResolveSuggestedReferenceParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    stableId: nonEmptyString,
    operationId: nonEmptyString,
    clientMode: ccbuddyDeliveryKindSchema,
    deliveryKind: ccbuddyDeliveryKindSchema,
  })
  .strict();
export type CCbuddyPluginsResolveSuggestedReferenceParams = z.infer<
  typeof ccbuddyPluginsResolveSuggestedReferenceParamsSchema
>;
export const ccbuddyPluginsSetEnabledParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString,
    enabled: z.boolean(),
    operationId: nonEmptyString.optional(),
    scope: ccbuddyPluginScopeSchema.optional(),
  })
  .strict();
export const ccbuddyPluginsSetEnabledResultSchema = z
  .object({
    plugin: ccbuddyPluginInfoSchema,
    enabled: z.boolean(),
  })
  .strict();
export type CCbuddyPluginsSetEnabledResult = z.infer<typeof ccbuddyPluginsSetEnabledResultSchema>;

// 商店信息（Store Listing）：目录条目携带的展示性元数据（显示名/icon/分类/作者/链接/hero/
// 示例提示词），全部可选，UI 缺失时按降级矩阵处理（字母头像/隐藏区块/省略信息行）。
// i18n 采用 `<字段>I18n` map，locale 解析复用 shared 的 plugin-display-name helper。
export const ccbuddyPluginStoreListingSchema = z
  .object({
    displayName: z.string().optional(),
    displayNameI18n: z.record(z.string(), z.string()).optional(),
    descriptionI18n: z.record(z.string(), z.string()).optional(),
    icon: z.string().optional(),
    category: z.string().optional(),
    author: z.string().optional(),
    authorUrl: z.string().optional(),
    homepage: z.string().optional(),
    privacyPolicy: z.string().optional(),
    termsOfService: z.string().optional(),
    heroImage: z.string().optional(),
    examplePrompts: z.array(z.string()).optional(),
    examplePromptsI18n: z.record(z.string(), z.array(z.string())).optional(),
    /**
     * 需要付费套餐才好用的插件：市场目录条目声明 `requiresPaidPlan: true`，
     * UI 在标题右侧展示提示图标。描述的是「使用条件」而非「插件是收费商品」——
     * 不参与安装门禁与计费，命名也不绑定具体套餐商品名。
     */
    requiresPaidPlan: z.boolean().optional(),
  })
  .strict();
export type CCbuddyPluginStoreListing = z.infer<typeof ccbuddyPluginStoreListingSchema>;

export const ccbuddyPluginsResolveSuggestedReferenceResultSchema = z
  .object({
    stableId: nonEmptyString,
    status: ccbuddyPluginSuggestedReferenceStatusSchema,
    marketplace: nonEmptyString.optional(),
    pluginName: nonEmptyString.optional(),
    sourceTrust: z.literal("official").optional(),
    // 官方 Marketplace listing 的可选展示投影；不参与身份、安装或权限判断。
    icon: z.string().optional(),
    listing: ccbuddyPluginStoreListingSchema.optional(),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
  })
  .strict()
  .superRefine((value, context) => {
    if (value.status !== "ready" && value.status !== "disabled" && value.status !== "missing") {
      return;
    }
    if (!value.marketplace || !value.pluginName || value.sourceTrust !== "official") {
      context.addIssue({
        code: "custom",
        message: "actionable suggested Plugin results require trusted install identity",
      });
    }
  });
export type CCbuddyPluginsResolveSuggestedReferenceResult = z.infer<
  typeof ccbuddyPluginsResolveSuggestedReferenceResultSchema
>;

export const ccbuddyPluginMarketplaceSummarySchema = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    source: jsonObjectSchema,
    description: z.string().optional(),
    lastUpdated: z.string().optional(),
    pluginCount: z.number().int().nonnegative(),
    isOfficial: z.boolean().optional(),
    // 目录顶层 featured 策展名单（商店「公开」分段 Featured 区）。
    featured: z.array(z.string()).optional(),
    refreshFailure: z
      .object({
        code: z.string(),
        failedAt: z.string(),
        message: z.string(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddyPluginMarketplaceSummary = z.infer<typeof ccbuddyPluginMarketplaceSummarySchema>;

export const ccbuddyAvailablePluginSummarySchema = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    marketplace: nonEmptyString,
    description: z.string().optional(),
    version: z.string().optional(),
    installed: z.boolean(),
    componentTypes: z.array(z.string()).optional(),
    listing: ccbuddyPluginStoreListingSchema.optional(),
  })
  .strict();
export type CCbuddyAvailablePluginSummary = z.infer<typeof ccbuddyAvailablePluginSummarySchema>;

export const ccbuddyInstalledPluginSummarySchema = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    marketplace: nonEmptyString,
    description: z.string().optional(),
    version: z.string().optional(),
    enabled: z.boolean(),
    scope: ccbuddyPluginScopeSchema,
    installPath: z.string().optional(),
    installedAt: z.string().optional(),
    componentTypes: z.array(z.string()).optional(),
    hookDetails: z.array(ccbuddyPluginHookDetailSchema).optional(),
    updateStatus: z.enum(["none", "update-available", "version-changed"]).optional(),
    latestVersion: z.string().optional(),
    listing: ccbuddyPluginStoreListingSchema.optional(),
  })
  .strict();
export type CCbuddyInstalledPluginSummary = z.infer<typeof ccbuddyInstalledPluginSummarySchema>;

export const ccbuddyPluginsOverviewParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    configScope: ccbuddyPluginScopeSchema.optional(),
  })
  .strict();
export const ccbuddyPluginsOverviewResultSchema = z
  .object({
    marketplaces: z.array(ccbuddyPluginMarketplaceSummarySchema),
    availablePlugins: z.array(ccbuddyAvailablePluginSummarySchema),
    installedPlugins: z.array(ccbuddyInstalledPluginSummarySchema),
    restorableBuiltins: z.array(ccbuddyAvailablePluginSummarySchema),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
    capability: z
      .object({
        supported: z.boolean(),
        reason: z.string().optional(),
      })
      .strict(),
  })
  .strict();
export type CCbuddyPluginsOverviewResult = z.infer<typeof ccbuddyPluginsOverviewResultSchema>;

export const ccbuddyPluginsMarketplaceAddParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    source: nonEmptyString,
    dryRun: z.boolean().optional(),
    operationId: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddyPluginsMarketplaceRemoveParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    marketplace: nonEmptyString,
  })
  .strict();
export const ccbuddyPluginsMarketplaceUpdateParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    marketplace: nonEmptyString.optional(),
    operationId: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddyPluginsMarketplaceMutationResultSchema = z
  .object({
    marketplace: ccbuddyPluginMarketplaceSummarySchema.optional(),
    marketplaces: z.array(ccbuddyPluginMarketplaceSummarySchema).optional(),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema).optional(),
  })
  .strict();
export type CCbuddyPluginsMarketplaceMutationResult = z.infer<
  typeof ccbuddyPluginsMarketplaceMutationResultSchema
>;

export const ccbuddyPluginsInstallParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginName: nonEmptyString,
    marketplace: nonEmptyString,
    scope: ccbuddyPluginScopeSchema.optional(),
    dryRun: z.boolean().optional(),
    operationId: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddyPluginsCancelOperationParamsSchema = z
  .object({
    operationId: nonEmptyString,
  })
  .strict();
export type CCbuddyPluginsCancelOperationParams = z.infer<
  typeof ccbuddyPluginsCancelOperationParamsSchema
>;

export const ccbuddyPluginsCancelOperationResultSchema = z
  .object({
    operationId: nonEmptyString,
    cancelled: z.boolean(),
  })
  .strict();
export type CCbuddyPluginsCancelOperationResult = z.infer<
  typeof ccbuddyPluginsCancelOperationResultSchema
>;
export const ccbuddyPluginsUninstallParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString.optional(),
    pluginName: nonEmptyString.optional(),
    marketplace: nonEmptyString.optional(),
    removeCache: z.boolean().optional(),
  })
  .strict();
export const ccbuddyPluginsInstallResultSchema = z
  .object({
    installedPlugins: z.array(ccbuddyInstalledPluginSummarySchema),
    dependencyClosure: z.array(z.string()),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
  })
  .strict();
export type CCbuddyPluginsInstallResult = z.infer<typeof ccbuddyPluginsInstallResultSchema>;

export const ccbuddyPluginsUninstallResultSchema = z
  .object({
    removedPlugin: ccbuddyInstalledPluginSummarySchema.optional(),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
  })
  .strict();
export type CCbuddyPluginsUninstallResult = z.infer<typeof ccbuddyPluginsUninstallResultSchema>;

export const ccbuddyPluginsUpdateParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString.optional(),
    marketplace: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddyPluginsRestoreBuiltinParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString,
  })
  .strict();
export const ccbuddyPluginsRestoreBuiltinResultSchema = z
  .object({
    pluginId: nonEmptyString,
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
  })
  .strict();
export type CCbuddyPluginsRestoreBuiltinResult = z.infer<
  typeof ccbuddyPluginsRestoreBuiltinResultSchema
>;

export const ccbuddyPluginsConfigureParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString,
    options: jsonObjectSchema,
    clearOptionKeys: z.array(nonEmptyString).optional(),
    scope: ccbuddyPluginScopeSchema.optional(),
    dryRun: z.boolean().optional(),
  })
  .strict();
export const ccbuddyPluginsConfigureResultSchema = z
  .object({
    pluginId: nonEmptyString,
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
  })
  .strict();
export type CCbuddyPluginsConfigureResult = z.infer<typeof ccbuddyPluginsConfigureResultSchema>;

export const ccbuddyPluginsResetConfigParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginId: nonEmptyString,
    scope: ccbuddyPluginScopeSchema.optional(),
  })
  .strict();
export type CCbuddyPluginsResetConfigParams = z.infer<typeof ccbuddyPluginsResetConfigParamsSchema>;

export const ccbuddyPluginsValidateParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginName: nonEmptyString.optional(),
    marketplace: nonEmptyString.optional(),
    source: nonEmptyString.optional(),
  })
  .strict();
export const ccbuddyPluginsValidateResultSchema = z
  .object({
    ok: z.boolean(),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema),
    compatibility: z
      .object({
        runnable: z.array(z.string()),
        diagnosticOnly: z.array(z.string()),
        unsupported: z.array(z.string()),
      })
      .strict(),
  })
  .strict();
export type CCbuddyPluginsValidateResult = z.infer<typeof ccbuddyPluginsValidateResultSchema>;

// plugins/describe：按需枚举单个插件的组件「名称 + 描述」。
// 已安装插件读本地缓存目录；未安装候选按需解析/临时 clone 源后枚举再清理。
export const ccbuddyPluginsDescribeParamsSchema = z
  .object({
    workspace: ccbuddyWorkspaceRefSchema,
    pluginName: nonEmptyString,
    marketplace: nonEmptyString,
  })
  .strict();
export const ccbuddyPluginsDescribeResultSchema = z
  .object({
    components: z.array(ccbuddyPluginComponentGroupSchema),
    diagnostics: z.array(ccbuddyPluginDiagnosticSchema).optional(),
    // 插件包内 plugin.json 的展示性回退字段；未安装候选详情页信息区在商店 listing 缺失时兜底。
    metadata: z
      .object({
        author: z.string().optional(),
        authorUrl: z.string().optional(),
        homepage: z.string().optional(),
        version: z.string().optional(),
      })
      .strict()
      .optional(),
  })
  .strict();
export type CCbuddyPluginsDescribeResult = z.infer<typeof ccbuddyPluginsDescribeResultSchema>;

export const ccbuddyAutomationScheduleRuleSchema = z
  .object({
    unit: z.enum(["minute", "hourly", "daily", "weekly", "monthly", "yearly"]),
    interval: z.number().int().positive(),
    hour: z.number().int().min(0).max(23),
    minute: z.number().int().min(0).max(59),
    anchorAt: z.number().int(),
    weekdays: z.array(z.number().int().min(0).max(6)).optional(),
    monthDays: z.array(z.number().int().min(1).max(31)).optional(),
    /** yearly 用：1-12 人类月份。缺省回退 anchorAt 的月份（兼容未写该字段的旧记录）。 */
    months: z.array(z.number().int().min(1).max(12)).optional(),
    monthlyMode: z.enum(["date", "weekday"]).optional(),
  })
  .strict();
export type CCbuddyAutomationScheduleRuleProtocol = z.infer<
  typeof ccbuddyAutomationScheduleRuleSchema
>;

/** 会话侧长间隔周期 carrier 的 unit 枚举（与 scheduleRule.unit 同集）。 */
export const ccbuddyAutomationIntervalUnitSchema = z.enum([
  "minute",
  "hourly",
  "daily",
  "weekly",
  "monthly",
  "yearly",
]);

export const ccbuddyAutomationProtocolSchema = z
  .object({
    automationId: nonEmptyString,
    title: z.string(),
    cronExpr: nonEmptyString,
    prompt: nonEmptyString,
    modelSelection: modelSelectionSchema.optional(),
    mode: ccbuddyTaskModeSchema.optional(),
    targetTaskId: nonEmptyString.optional(),
    enabled: z.boolean(),
    lifecycleStatus: z.enum(["active", "completed", "failed", "paused"]),
    nextRunAt: timestampMsSchema.optional(),
    lastRunAt: timestampMsSchema.optional(),
    runCount: z.number().int().nonnegative(),
    recurring: z.boolean(),
    maxRuns: z.number().int().positive().optional(),
    // 自定义重复规则；缺省时调度回退到解析 cronExpr。会话卡片必须读到本字段才能展示
    // cron 无法表达的真实间隔（如每50小时、每40天，兼容 cronExpr 只是 0 * * * *）。
    scheduleRule: ccbuddyAutomationScheduleRuleSchema.optional(),
  })
  .strict();
export type CCbuddyAutomationProtocol = z.infer<typeof ccbuddyAutomationProtocolSchema>;

export const ccbuddyAutomationCreateParamsSchema = z
  .object({
    title: z.string().optional(),
    cronExpr: nonEmptyString,
    relativeDelayMinutes: z.number().int().positive().max(525_600).optional(),
    prompt: nonEmptyString,
    modelSelection: modelSelectionSchema.optional(),
    mode: ccbuddyTaskModeSchema.optional(),
    targetTaskId: nonEmptyString.optional(),
    botDeliveryTarget: ccbuddyAutomationBotDeliveryTargetSchema.optional(),
    recurring: z.boolean().optional(),
    maxRuns: z.number().int().positive().optional(),
    // 会话侧自定义重复 carrier：每 N 分钟/小时/天/周/月/年均通过此字段归一化为权威 scheduleRule，
    // cronExpr 仅作合法兼容展示。
    intervalUnit: ccbuddyAutomationIntervalUnitSchema.optional(),
    interval: z.number().int().min(1).max(200).optional(),
  })
  .strict()
  // intervalUnit 与 interval 必须配对提交（只传一个无法确定真实间隔）。
  .refine((input) => (input.intervalUnit === undefined) === (input.interval === undefined), {
    message: "intervalUnit and interval must be set together",
    path: ["interval"],
  })
  // 周期 carrier 与一次性相对延迟语义冲突，禁止同传。
  .refine((input) => input.intervalUnit === undefined || input.relativeDelayMinutes === undefined, {
    message: "intervalUnit cannot combine with a relative delayMinutes",
    path: ["intervalUnit"],
  })
  .refine((input) => input.intervalUnit === undefined || input.recurring !== false, {
    message: "intervalUnit is a recurring carrier and cannot combine with recurring=false",
    path: ["recurring"],
  })
  .refine((input) => input.intervalUnit === undefined || input.maxRuns === undefined, {
    message: "intervalUnit is a recurring carrier and cannot combine with maxRuns",
    path: ["maxRuns"],
  });
export type CCbuddyAutomationCreateProtocolParams = z.infer<
  typeof ccbuddyAutomationCreateParamsSchema
>;

export const ccbuddyAutomationCreateResultSchema = z
  .object({ automation: ccbuddyAutomationProtocolSchema })
  .strict();
export type CCbuddyAutomationCreateProtocolResult = z.infer<
  typeof ccbuddyAutomationCreateResultSchema
>;

export const ccbuddyAutomationUpdateParamsSchema = z
  .object({
    automationId: nonEmptyString,
    title: nonEmptyString.optional(),
    cronExpr: nonEmptyString.optional(),
    prompt: nonEmptyString.optional(),
    recurring: z.boolean().optional(),
    maxRuns: z.number().int().positive().nullable().optional(),
    // 会话侧自定义重复 carrier（同 create 侧语义）。
    intervalUnit: ccbuddyAutomationIntervalUnitSchema.optional(),
    interval: z.number().int().min(1).max(200).optional(),
  })
  .strict()
  .refine(
    (input) =>
      input.title !== undefined ||
      input.cronExpr !== undefined ||
      input.prompt !== undefined ||
      input.recurring !== undefined ||
      input.maxRuns !== undefined ||
      input.intervalUnit !== undefined,
    { message: "automation update requires at least one field" },
  )
  .refine((input) => input.maxRuns !== null || input.recurring === true, {
    message: "clearing maxRuns requires recurring=true",
    path: ["maxRuns"],
  })
  .refine((input) => input.recurring !== true || typeof input.maxRuns !== "number", {
    message: "recurring=true cannot be combined with a numeric maxRuns",
    path: ["maxRuns"],
  })
  // intervalUnit 与 interval 必须配对提交（同 create 侧语义）。
  .refine((input) => (input.intervalUnit === undefined) === (input.interval === undefined), {
    message: "intervalUnit and interval must be set together",
    path: ["interval"],
  })
  .refine((input) => input.intervalUnit === undefined || input.recurring !== false, {
    message: "intervalUnit is a recurring carrier and cannot combine with recurring=false",
    path: ["recurring"],
  })
  .refine(
    (input) =>
      input.intervalUnit === undefined ||
      input.maxRuns === undefined ||
      (input.maxRuns === null && input.recurring === true),
    {
      message:
        "intervalUnit is a recurring carrier and only allows maxRuns=null with recurring=true",
      path: ["maxRuns"],
    },
  );
export type CCbuddyAutomationUpdateProtocolParams = z.infer<
  typeof ccbuddyAutomationUpdateParamsSchema
>;
export const ccbuddyAutomationUpdateResultSchema = z
  .object({ automation: ccbuddyAutomationProtocolSchema })
  .strict();
export type CCbuddyAutomationUpdateProtocolResult = z.infer<
  typeof ccbuddyAutomationUpdateResultSchema
>;

export const ccbuddyAutomationListParamsSchema = z.object({}).strict();
export type CCbuddyAutomationListProtocolParams = z.infer<typeof ccbuddyAutomationListParamsSchema>;
export const ccbuddyAutomationListResultSchema = z
  .object({ automations: z.array(ccbuddyAutomationProtocolSchema) })
  .strict();
export type CCbuddyAutomationListProtocolResult = z.infer<typeof ccbuddyAutomationListResultSchema>;

export const ccbuddyAutomationCheckTaskBindingParamsSchema = z
  .object({ targetTaskId: nonEmptyString })
  .strict();
export type CCbuddyAutomationCheckTaskBindingProtocolParams = z.infer<
  typeof ccbuddyAutomationCheckTaskBindingParamsSchema
>;
export const ccbuddyAutomationCheckTaskBindingResultSchema = z
  .object({ bound: z.boolean() })
  .strict();
export type CCbuddyAutomationCheckTaskBindingProtocolResult = z.infer<
  typeof ccbuddyAutomationCheckTaskBindingResultSchema
>;

export const ccbuddyAutomationDeleteParamsSchema = z
  .object({ automationId: nonEmptyString })
  .strict();
export type CCbuddyAutomationDeleteProtocolParams = z.infer<
  typeof ccbuddyAutomationDeleteParamsSchema
>;
export const ccbuddyAutomationDeleteResultSchema = z.object({ deleted: z.boolean() }).strict();
export type CCbuddyAutomationDeleteProtocolResult = z.infer<
  typeof ccbuddyAutomationDeleteResultSchema
>;

// ---- Off-Peak（闲时任务）会话内创建协议----
// 与 automation 兄弟并列（独立域，禁止互相复用标记/表）。workspace 由 host 端从
// 当前 session 注入，不进协议参数（对称 automation/create）。permissionMode 只开放产品
// 四档词表；缺省解析在 host 端（yolo / allowed_models 末位 / 最高推理档）。
export const ccbuddyOffPeakPermissionModeSchema = z.enum(["build", "edit", "plan", "yolo"]);
export type CCbuddyOffPeakProtocolPermissionMode = z.infer<
  typeof ccbuddyOffPeakPermissionModeSchema
>;

export const ccbuddyOffPeakCreateParamsSchema = z
  .object({
    title: nonEmptyString,
    prompt: nonEmptyString,
    permissionMode: ccbuddyOffPeakPermissionModeSchema.optional(),
    model: nonEmptyString.optional(),
    thoughtLevel: nonEmptyString.optional(),
    // 会话内创建绑定当前会话（对齐 automation/create 的 targetTaskId），由 CLI 端口填入。
    boundSessionId: nonEmptyString.optional(),
  })
  .strict();
export type CCbuddyOffPeakCreateProtocolParams = z.infer<typeof ccbuddyOffPeakCreateParamsSchema>;

// 协议侧任务快照：轮尾卡片与 OffPeakList 的最小字段面。
// 不暴露 serverTicketId（跨边界禁带）。
export const ccbuddyOffPeakTaskSnapshotSchema = z
  .object({
    offPeakTaskId: nonEmptyString,
    title: z.string(),
    status: z.enum(["queued", "paused", "running", "completed", "failed", "cancelled"]),
    queuePosition: z.number().int().positive().optional(),
    sessionId: nonEmptyString.optional(),
    createdAt: z.number().int().nonnegative(),
  })
  .strict();
export type CCbuddyOffPeakTaskProtocolSnapshot = z.infer<typeof ccbuddyOffPeakTaskSnapshotSchema>;

// 失败分类跨协议保真（镜像 shared OffPeakTaskCreateResult 的判别联合，错误不降级为字符串）。
// model 白名单预校失败复用 client_validation 分类 + errorCode "model_not_allowed"，不扩分类枚举。
export const ccbuddyOffPeakCreateResultSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), task: ccbuddyOffPeakTaskSnapshotSchema }).strict(),
  z
    .object({
      ok: z.literal(false),
      failureStage: z.enum(["client_validation", "ticket_request", "local_persist"]),
      errorCategory: z.enum([
        "client_validation",
        "eligibility_3101",
        "quota_3103",
        "network",
        "invalid_response",
        "local_persist",
        "unknown",
      ]),
      errorCode: z.string(),
    })
    .strict(),
]);
export type CCbuddyOffPeakCreateProtocolResult = z.infer<typeof ccbuddyOffPeakCreateResultSchema>;

export const ccbuddyOffPeakListParamsSchema = z.object({}).strict();
export type CCbuddyOffPeakListProtocolParams = z.infer<typeof ccbuddyOffPeakListParamsSchema>;
export const ccbuddyOffPeakListResultSchema = z
  .object({ tasks: z.array(ccbuddyOffPeakTaskSnapshotSchema) })
  .strict();
export type CCbuddyOffPeakListProtocolResult = z.infer<typeof ccbuddyOffPeakListResultSchema>;

export const ccbuddyProtocolMethods = {
  runtimeCapabilities: "runtime/capabilities",
  computerUseOperationEvent: "computer-use/operation-event",
  sessionCreate: "session/create",
  sessionResume: "session/resume",
  sessionList: "session/list",
  sessionSubagents: "session/subagents",
  sessionRequestRuntimePreferences: "session/requestRuntimePreferences",
  sessionRead: "session/read",
  sessionMessages: "session/messages",
  sessionEvents: "session/events",
  sessionDebug: "session/debug",
  sessionSubscribe: "session/subscribe",
  // @deprecated（部分）：send 主路径已收敛 v4 sendText；仅剩 adapter 附件
  // 回退分支消费（v4 attachmentRef 上传/寄存命令面未建模），待附件命令面落地后移除。
  sessionSend: "session/send",
  // @deprecated：host 客户端方法已删（stop 已收敛 v4 stop 命令）。
  // wire case 留兼容（transport bypass 名单仍引用），随旧词整体删除时一并移除。
  sessionStop: "session/stop",
  // @deprecated：host 客户端方法已删（已收敛 v4 cancelBackgroundWork 命令）。
  // wire case 留兼容，随旧词整体删除时一并移除。
  sessionCancelBackgroundTask: "session/cancelBackgroundTask",
  // @deprecated：host 客户端方法已删（v4 forkAssistant 原生 handler 经
  // forkSessionAtMessage 钩子直调 server-operations.forkSession op）。wire case 与
  // fork params/result schema 保留＝op 存活面；fork record 归 v4 原生重写。
  sessionFork: "session/fork",
  sessionCompact: "session/compact",
  sessionGoal: "session/goal",
  sessionClose: "session/close",
  // setModel 仍被 ccbuddySessionService 的 desktop 旧链路消费；replayable
  // switchModelConfig 已直接由目标 Environment Registry 解析 Selection。
  sessionSetModel: "session/setModel",
  // replayable facade 的思考深度/模式已收敛 v4 switchModelConfig/
  // switchCollaborationMode；剩余消费 = ccbuddySessionService（desktop 旧链路，随
  // 桌面 v4 UI 收口清零）与 setMode 的 auto 值残留（v4 值域刻意排除 auto）。
  sessionSetThoughtLevel: "session/setThoughtLevel",
  sessionSetMode: "session/setMode",
  workspaceReadPresentation: "workspace/readPresentation",
  workspaceHookTrustGrant: "workspace/hooks/trustGrant",
  // 进程级 Account Provider Config 与 workspace 运行目录分离。
  providerUpdateAccountConfig: "provider/updateAccountConfig",
  workspaceUpdateInteractionPreferences: "workspace/updateInteractionPreferences",
  workspaceUpdateModelIoPreferences: "workspace/updateModelIoPreferences",
  // Off-Peak 工具面门禁是 workspace 级事实（灰度 + 本地/远程），由 host 在 agent 就绪时同步；
  // CLI 对 legacy create/resume 与 v4 冷恢复统一读取。旧 CLI method-not-found → host 降级忽略。
  workspaceUpdateOffPeakToolPolicy: "workspace/updateOffPeakToolPolicy",
  // 动态工作流灰度门禁：同 Off-Peak 的同步模式。
  workspaceUpdateDynamicWorkflowPolicy: "workspace/updateDynamicWorkflowPolicy",
  // LLM 执行面在 CLI，直连不可行；消费仅 services 内部
  // （commit message），待 v4 workspace 查询/命令面覆盖后移除。
  workspaceGenerateText: "workspace/generateText",
  workspaceCancelGenerateText: "workspace/cancelGenerateText",
  providerTestModelConnectivity: "provider/testModelConnectivity",
  mcpList: "mcp/list",
  pluginsList: "plugins/list",
  pluginsReferenceCatalog: "plugins/referenceCatalog",
  pluginsReferenceCatalogWithCategory: "plugins/referenceCatalogWithCategory",
  skillsReferenceCatalog: "skills/referenceCatalog",
  // 已保存工作流的 GUI 中枢：workspace 级、无会话。
  workflowsList: "workflows/list",
  workflowsGet: "workflows/get",
  workflowsUpdateMeta: "workflows/updateMeta",
  workflowsDelete: "workflows/delete",
  workflowsRuns: "workflows/runs",
  // 在项目档 / 全局档之间移动同名文件。
  workflowsMove: "workflows/move",
  pluginsResolveSuggestedReference: "plugins/resolveSuggestedReference",
  pluginsSetEnabled: "plugins/setEnabled",
  pluginsOverview: "plugins/overview",
  pluginsMarketplaceAdd: "plugins/marketplace/add",
  pluginsMarketplaceRemove: "plugins/marketplace/remove",
  pluginsMarketplaceUpdate: "plugins/marketplace/update",
  pluginsInstall: "plugins/install",
  pluginsCancelOperation: "plugins/cancelOperation",
  pluginsUninstall: "plugins/uninstall",
  pluginsUpdate: "plugins/update",
  pluginsRestoreBuiltin: "plugins/restoreBuiltin",
  pluginsConfigure: "plugins/configure",
  pluginsResetConfig: "plugins/resetConfig",
  pluginsValidate: "plugins/validate",
  pluginsDescribe: "plugins/describe",
  automationCreate: "automation/create",
  automationUpdate: "automation/update",
  automationCheckTaskBinding: "automation/checkTaskBinding",
  automationList: "automation/list",
  automationDelete: "automation/delete",
  // Off-Peak 会话内创建：与 automation 兄弟并列的独立方法族。
  offPeakCreate: "offPeak/create",
  offPeakList: "offPeak/list",
  // @deprecated：host 消费已清零（ccbuddyAgentService 改走 v4/usage/stats）。
  // 仅剩 CLI server 的 wire 兼容 case；随旧词整体删除时一并移除。
  usageStats: "usage/stats",
  // CCbuddy Protocol 对 agent 只暴露 session-first 方法；task 是 UI 投影概念，不能泄露进协议方法名。
  // @deprecated：host 已改走 v4/conversation/usage；后续与 usage/stats 一并移除。
  sessionUsage: "session/usage",
  // 资源管理器：CLI 回报其 MCP 子进程 pid 与插件归属（纯内存，无 I/O），采样在 Host 侧完成。
  processChildProcesses: "process/childProcesses",
  interactionRequestPermission: "interaction/requestPermission",
  interactionRequestUserInput: "interaction/requestUserInput",
  interactionRequestProviderRuntimeHeaders: "interaction/requestProviderRuntimeHeaders",
  interactionRequestOfficialMcpAuthHeaders: "interaction/requestOfficialMcpAuthHeaders",
  // browser-use 反向请求由 agent 发起，host 转给 main 中的 CDP executor。
  interactionBrowserList: "interaction/browserList",
  interactionBrowserExecute: "interaction/browserExecute",
} as const;

export type CCbuddyProtocolMethod =
  (typeof ccbuddyProtocolMethods)[keyof typeof ccbuddyProtocolMethods];

export const ccbuddyProtocolEmptyResultSchema = z.object({}).strict();

// 最新 V4 主链已不再依赖旧版全量方法表；这里仅保留仍被兼容测试和 browser broker
// 消费的最小契约集合，避免重新引入已移除的 legacy 方法。
export const ccbuddyProtocolSessionMethodContracts = {
  [ccbuddyProtocolMethods.workspaceHookTrustGrant]: {
    params: ccbuddyWorkspaceHookTrustGrantParamsSchema,
    result: ccbuddyWorkspaceHookTrustGrantResultSchema,
  },
  [ccbuddyProtocolMethods.mcpList]: {
    params: ccbuddyMcpListParamsSchema,
    result: ccbuddyMcpListResultSchema,
  },
  [ccbuddyProtocolMethods.interactionBrowserList]: {
    params: ccbuddyBrowserListParamsSchema,
    result: ccbuddyBrowserListResultSchema,
  },
  [ccbuddyProtocolMethods.interactionBrowserExecute]: {
    params: ccbuddyBrowserExecuteParamsSchema,
    result: ccbuddyBrowserExecuteResultSchema,
  },
} as const satisfies Partial<
  Record<CCbuddyProtocolMethod, { params: z.ZodTypeAny; result: z.ZodTypeAny }>
>;

export type CCbuddyProtocolSessionMethodContract =
  (typeof ccbuddyProtocolSessionMethodContracts)[keyof typeof ccbuddyProtocolSessionMethodContracts];

/** 仅存储准备子进程的私有控制帧，原始路径不进入业务事件或遥测。 */
export const ccbuddyStoragePreparationFrameSchema = z.discriminatedUnion("method", [
  z
    .object({
      method: z.literal("startup/storagePath"),
      params: z.object({ path: z.string().min(1).max(32768) }).strict(),
    })
    .strict(),
  z
    .object({ method: z.literal("startup/storagePrepared"), params: z.object({}).strict() })
    .strict(),
  z
    .object({ method: z.literal("startup/storageState"), params: ccbuddyStorageStartupStateSchema })
    .strict(),
]);
export const ccbuddyStoragePathReadySchema = z
  .object({ method: z.literal("startup/storagePathReady"), reuse: z.boolean().optional() })
  .strict();
export * from "../localTtft.js";

// 桌面本地 TTFT 的严格事实合同；检查点不能替代实际内容帧。
export { localTtftFactsSchema } from "../localTtft.js";
