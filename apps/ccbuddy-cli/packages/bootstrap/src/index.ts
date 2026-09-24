// Bootstrap public API surface.

export * from "./app/create-app.js";
export type {
  ListCCbuddySessionsOptions,
  PromptInput,
  ResolveLatestSessionOptions,
  ResumeOptions,
  RunCCbuddyProtocolAgentOptions,
  SendInputOptions,
  SendInputResult,
  SetLocaleResult,
  SteerTurnOptions,
  SubmitPromptOptions,
  UserPromptInput,
  CCbuddyApp,
  CCbuddyAppOptions,
  CCbuddyModelOption,
} from "./app/types.js";
export * from "./auth-login.js";
export {
  inspectCCbuddyCustomCommand,
  listCCbuddyCustomCommands,
  loadCCbuddyCustomCommand,
} from "./custom-commands.js";
export type {
  InspectCCbuddyCustomCommandOptions,
  ListCCbuddyCustomCommandsOptions,
  CCbuddyCustomCommandInspection,
} from "./custom-commands.js";
export { createModelAdapter } from "./model-factory.js";
export type { CreateModelAdapterOptions } from "./model-factory.js";
export { startProcessProviderRegistryRuntime } from "./app/process-provider-registry-runtime.js";
export type { ProcessProviderRegistryRuntimeOptions } from "./app/process-provider-registry-runtime.js";
export {
  addCCbuddyPluginMarketplace,
  getCCbuddyPluginsOverview,
  installCCbuddyMarketplacePlugin,
  listCCbuddyPlugins,
  removeCCbuddyPluginMarketplace,
  resolveCCbuddyPlugins,
  setCCbuddyPluginEnabled,
  uninstallCCbuddyMarketplacePlugin,
  updateCCbuddyMarketplacePlugin,
  updateCCbuddyPluginMarketplace,
  validateCCbuddyPluginPath,
} from "./plugins.js";
export type {
  AddCCbuddyMarketplaceOptions,
  InstallCCbuddyMarketplacePluginOptions,
  ListCCbuddyPluginsOptions,
  RemoveCCbuddyMarketplaceOptions,
  ResolveCCbuddyPluginsOptions,
  SetCCbuddyPluginEnabledOptions,
  SetCCbuddyPluginEnabledResult,
  UninstallCCbuddyMarketplacePluginOptions,
  UpdateCCbuddyMarketplaceOptions,
  UpdateCCbuddyMarketplacePluginOptions,
  ValidateCCbuddyPluginPathOptions,
  CCbuddyAvailablePluginData,
  CCbuddyInstalledPluginData,
  CCbuddyMarketplaceSummaryData,
  CCbuddyMarketplaceUpdateData,
  CCbuddyPluginInstallData,
  CCbuddyPluginUpdateData,
  CCbuddyPluginsOverviewData,
} from "./plugins.js";
export { runCCbuddyProtocolAgent } from "./ccbuddy-protocol-entrypoint.js";
// Exposed for the CLI's --output-format stream-json: it needs the same event
// shape the protocol server emits, rather than inventing a second one.
export { mapSessionEvent } from "./ccbuddy-protocol/session-mapper.js";
export { prepareCCbuddyTelemetryEnv, shutdownCCbuddyTelemetry } from "./telemetry-bootstrap.js";
export type { SessionTranscriptMessage, SessionTranscriptPart } from "./session-transcript.js";
export { listCCbuddySessions, resolveLatestSession } from "./sessions.js";
export { inspectCCbuddySkill, listCCbuddySkills } from "./skills.js";
export type {
  InspectCCbuddySkillOptions,
  ListCCbuddySkillsOptions,
  CCbuddySkillInspection,
} from "./skills.js";
// Exposed for the CLI's headless slash routing: it must decide "is this a real
// custom command?" with the *same* reserved-name gate the app facade's
// customCommandPromptResolver applies, or the two disagree and a reserved name
// reaches the model as literal prompt text. See prompt-command.ts.
export { isReservedCCbuddySlashCommandName } from "./slash-command-surface.js";
export {
  grantWorkspaceHookTrust,
  inspectWorkspaceHookTrust,
  revokeWorkspaceHookTrustCli,
} from "./workspace-hook-trust-cli.js";
export type {
  WorkspaceHookTrustCliItem,
  WorkspaceHookTrustCliStatus,
  WorkspaceHookTrustCliTarget,
} from "./workspace-hook-trust-cli.js";
