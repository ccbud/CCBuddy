import type { TuiReadClipboardImage, TuiWriteClipboardText } from "@ccbuddy/tui";
import type { UiLocale } from "@ccbuddy/i18n";
import type { Logger } from "@ccbuddy/contracts";
import type {
  createManagedCdpBrowserRuntime,
  ManagedCdpBrowserRuntimeOptions,
} from "@ccbuddy/adapters/browser";
import type {
  createModelAdapter,
  createCCbuddyApp,
  CreateModelAdapterOptions,
  configureCodingPlanApiKey,
  ConfigureCodingPlanApiKeyOptions,
  inspectCCbuddySkill,
  inspectWorkspaceHookTrust,
  grantWorkspaceHookTrust,
  revokeWorkspaceHookTrustCli,
  inspectCCbuddyCustomCommand,
  InspectCCbuddyCustomCommandOptions,
  InspectCCbuddySkillOptions,
  loginCCbuddyCli,
  loginBigmodelCodingPlan,
  LoginBigmodelCodingPlanOptions,
  LoginCCbuddyCliOptions,
  listCCbuddyCustomCommands,
  ListCCbuddyCustomCommandsOptions,
  loadCCbuddyCustomCommand,
  listCCbuddySessions,
  listCCbuddySkills,
  ListCCbuddySessionsOptions,
  ListCCbuddySkillsOptions,
  logoutCCbuddyCli,
  LogoutCCbuddyCliOptions,
  resolveLatestSession,
  ResolveLatestSessionOptions,
  RunCCbuddyProtocolAgentOptions,
  prepareCCbuddyTelemetryEnv,
  startProcessProviderRegistryRuntime,
  shutdownCCbuddyTelemetry,
  CCbuddyAppOptions,
} from "@ccbuddy/bootstrap";
import type { CliEnv, DotenvLoadResult, LoadCliDotenvOptions } from "./env.js";
import type { PluginsCommandOverrides } from "./plugins-command.js";
import type { CliShutdownProcess } from "./shutdown.js";
import type { resolveWorkspaceGitBranch } from "./tui-workspace-git.js";

export type BootstrapModule = typeof import("@ccbuddy/bootstrap");

export interface RunDependencies extends PluginsCommandOverrides {
  protocolLifecycle?: RunCCbuddyProtocolAgentOptions["lifecycle"];
  protocolInput?: NodeJS.ReadableStream;
  createManagedCdpBrowserRuntime?: (
    options?: ManagedCdpBrowserRuntimeOptions,
  ) => ReturnType<typeof createManagedCdpBrowserRuntime>;
  createModelAdapter?: (
    options?: CreateModelAdapterOptions,
  ) => ReturnType<typeof createModelAdapter>;
  createCCbuddyApp?: (
    options?: CCbuddyAppOptions,
  ) => Awaited<ReturnType<typeof createCCbuddyApp>> | ReturnType<typeof createCCbuddyApp>;
  /**
   * Session-event shaper for --output-format stream-json. Defaults to the
   * bootstrap module's, which is also what the protocol server uses; injectable
   * so a caller that supplies its own `createCCbuddyApp` (tests, embedders) can
   * still stream, since the bootstrap module is not loaded on that path.
   */
  mapSessionEvent?: BootstrapModule["mapSessionEvent"];
  cwd?: () => string;
  env?: CliEnv;
  inspectSkill?: (options: InspectCCbuddySkillOptions) => ReturnType<typeof inspectCCbuddySkill>;
  inspectWorkspaceHookTrust?: typeof inspectWorkspaceHookTrust;
  grantWorkspaceHookTrust?: typeof grantWorkspaceHookTrust;
  revokeWorkspaceHookTrustCli?: typeof revokeWorkspaceHookTrustCli;
  inspectCustomCommand?: (
    options: InspectCCbuddyCustomCommandOptions,
  ) => ReturnType<typeof inspectCCbuddyCustomCommand>;
  loginCCbuddyCli?: (options?: LoginCCbuddyCliOptions) => ReturnType<typeof loginCCbuddyCli>;
  loginBigmodelCodingPlan?: (
    options?: LoginBigmodelCodingPlanOptions,
  ) => ReturnType<typeof loginBigmodelCodingPlan>;
  configureCodingPlanApiKey?: (
    options: ConfigureCodingPlanApiKeyOptions,
  ) => ReturnType<typeof configureCodingPlanApiKey>;
  loadDotenv?: (options?: LoadCliDotenvOptions) => DotenvLoadResult;
  prepareCCbuddyTelemetryEnv?: typeof prepareCCbuddyTelemetryEnv;
  projectConfigPath?: string;
  listSessions?: (options: ListCCbuddySessionsOptions) => ReturnType<typeof listCCbuddySessions>;
  listCustomCommands?: (
    options: ListCCbuddyCustomCommandsOptions,
  ) => ReturnType<typeof listCCbuddyCustomCommands>;
  loadCustomCommand?: (
    options: InspectCCbuddyCustomCommandOptions,
  ) => ReturnType<typeof loadCCbuddyCustomCommand>;
  // headless slash 路由要和 app facade 的保留名 gate 用同一个判据；默认取 bootstrap 的，
  // 注入点只为让单测不必拉起整个 bootstrap 模块。见 prompt-command.ts。
  isReservedSlashCommandName?: BootstrapModule["isReservedCCbuddySlashCommandName"];
  listSkills?: (options: ListCCbuddySkillsOptions) => ReturnType<typeof listCCbuddySkills>;
  logger?: Logger;
  readClipboardImage?: TuiReadClipboardImage;
  writeClipboardText?: TuiWriteClipboardText;
  resolveLatestSession?: (
    options: ResolveLatestSessionOptions,
  ) => ReturnType<typeof resolveLatestSession>;
  resolveWorkspaceGitBranch?: typeof resolveWorkspaceGitBranch;
  logoutCCbuddyCli?: (options?: LogoutCCbuddyCliOptions) => ReturnType<typeof logoutCCbuddyCli>;
  runCCbuddyProtocolAgent?: (options?: RunCCbuddyProtocolAgentOptions) => Promise<void>;
  runTui?: typeof import("@ccbuddy/tui").runTui;
  skipUserConfig?: boolean;
  userConfigPath?: string;
  exitProcess?: (code: number) => void;
  shutdownCleanupTimeoutMs?: number;
  shutdownProcess?: CliShutdownProcess;
  startProcessProviderRegistryRuntime?: typeof startProcessProviderRegistryRuntime;
  shutdownCCbuddyTelemetry?: typeof shutdownCCbuddyTelemetry;
}

export type CliPermissionMode = "build" | "plan" | "edit" | "yolo";
export type CliRuntimeMode = CliPermissionMode | "auto";

export interface CliModeState {
  current?: CliRuntimeMode;
  override?: CliPermissionMode;
}

export interface CliTargetRequest {
  objective: string;
  replaceExisting: boolean;
}

export type ModeCapableApp = Awaited<ReturnType<typeof createCCbuddyApp>> & {
  getMode?: () => CliRuntimeMode;
  setLocale?: (locale: UiLocale) => Promise<{ locale: "en-US" | "zh-CN" }>;
  setMode?: (mode: CliRuntimeMode) => Promise<{ mode: CliRuntimeMode }>;
};

export interface CliResumeRequest {
  continueSession: boolean;
  resumeSessionId?: string;
}
