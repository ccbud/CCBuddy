// 平台能力面收敛：设置页「插件管理」的薄服务接口。
//
// 背景：pluginManagementStore / usePluginUninstall 过去直接注入 ICCbuddyAgentService，
// UI 层因此散布 13 个 plugins/* 旧协议词的消费点。收敛为独立薄 service 后，UI 只依赖
// 本接口；plugins/* 词表的 host 侧消费点收拢到 pluginManagementService 一处（插件的
// 事实源在 ccbuddy-cli 进程，服务实现仍经 agent 协议往返——plugins 词表的收口归属
// 插件能力面自身的协议演进，不在会话 v4 词表范围内）。
// 注意与既有 IPluginsService（已 retired 的 marketplace pluginStore 通道）区分：
// 那套接口按 pluginName+marketplace 寻址且方法语义过时，不复用避免签名冲突。
import type { Event } from "@ccbuddy/rpc";
import type {
  CCbuddyPluginOperationProgressNotification,
  CCbuddyPluginsConfigureResult,
  CCbuddyPluginsCancelOperationResult,
  CCbuddyPluginsDescribeResult,
  CCbuddyPluginsInstallResult,
  CCbuddyPluginsListResult,
  CCbuddyPluginsMarketplaceMutationResult,
  CCbuddyPluginsOverviewResult,
  CCbuddyPluginsReferenceCatalogResult,
  CCbuddyPluginsRestoreBuiltinResult,
  CCbuddyPluginsSetEnabledResult,
  CCbuddyPluginsUninstallResult,
  CCbuddyPluginsValidateResult,
} from "@ccbuddy/shared";
import { ServiceChannels } from "@ccbuddy/shared";
import { createServiceDescriptor } from "../descriptors.js";
import type {
  CCbuddyAgentAddPluginMarketplaceParams,
  CCbuddyAgentConfigurePluginParams,
  CCbuddyAgentCancelPluginOperationParams,
  CCbuddyAgentDescribePluginParams,
  CCbuddyAgentInstallPluginParams,
  CCbuddyAgentPluginReferenceCatalogParams,
  CCbuddyAgentResolveSuggestedPluginReferenceParams,
  CCbuddyAgentResetPluginConfigParams,
  CCbuddyAgentPluginViewParams,
  CCbuddyAgentRemovePluginMarketplaceParams,
  CCbuddyAgentRestoreBuiltinPluginParams,
  CCbuddyAgentSetPluginEnabledParams,
  CCbuddyAgentUninstallPluginParams,
  CCbuddyAgentUpdatePluginMarketplaceParams,
  CCbuddyAgentUpdatePluginParams,
  CCbuddyAgentValidatePluginParams,
} from "../ccbuddy-agent/ccbuddyAgentPluginParams.js";

export interface IPluginManagementService {
  listPlugins(params: CCbuddyAgentPluginViewParams): Promise<CCbuddyPluginsListResult>;
  /**
   * Plugin 对话引用 catalog：
   * 带 sessionId → session-owned 冻结 catalog；不带 → workspace 当前 catalog。
   * 实现路由到 workspace 级 agent client，不走插件管理独立进程。
   */
  getPluginReferenceCatalog(
    params: CCbuddyAgentPluginReferenceCatalogParams,
  ): Promise<CCbuddyPluginsReferenceCatalogResult>;
  resolveSuggestedPluginReference(
    params: CCbuddyAgentResolveSuggestedPluginReferenceParams,
  ): Promise<import("@ccbuddy/shared").CCbuddyPluginsResolveSuggestedReferenceResult>;
  onDynamicPluginOperationProgress(
    operationId: string,
  ): Event<CCbuddyPluginOperationProgressNotification>;
  getPluginsOverview(params: CCbuddyAgentPluginViewParams): Promise<CCbuddyPluginsOverviewResult>;
  addPluginMarketplace(
    params: CCbuddyAgentAddPluginMarketplaceParams,
  ): Promise<CCbuddyPluginsMarketplaceMutationResult>;
  removePluginMarketplace(
    params: CCbuddyAgentRemovePluginMarketplaceParams,
  ): Promise<CCbuddyPluginsMarketplaceMutationResult>;
  updatePluginMarketplace(
    params: CCbuddyAgentUpdatePluginMarketplaceParams,
  ): Promise<CCbuddyPluginsMarketplaceMutationResult>;
  installPlugin(params: CCbuddyAgentInstallPluginParams): Promise<CCbuddyPluginsInstallResult>;
  cancelPluginOperation(
    params: CCbuddyAgentCancelPluginOperationParams,
  ): Promise<CCbuddyPluginsCancelOperationResult>;
  uninstallPlugin(
    params: CCbuddyAgentUninstallPluginParams,
  ): Promise<CCbuddyPluginsUninstallResult>;
  updatePlugin(params: CCbuddyAgentUpdatePluginParams): Promise<CCbuddyPluginsInstallResult>;
  restoreBuiltinPlugin(
    params: CCbuddyAgentRestoreBuiltinPluginParams,
  ): Promise<CCbuddyPluginsRestoreBuiltinResult>;
  configurePlugin(
    params: CCbuddyAgentConfigurePluginParams,
  ): Promise<CCbuddyPluginsConfigureResult>;
  resetPluginConfig(
    params: CCbuddyAgentResetPluginConfigParams,
  ): Promise<CCbuddyPluginsConfigureResult>;
  validatePlugin(params: CCbuddyAgentValidatePluginParams): Promise<CCbuddyPluginsValidateResult>;
  describePlugin(params: CCbuddyAgentDescribePluginParams): Promise<CCbuddyPluginsDescribeResult>;
  setPluginEnabled(
    params: CCbuddyAgentSetPluginEnabledParams,
  ): Promise<CCbuddyPluginsSetEnabledResult>;
}

export const IPluginManagementService = createServiceDescriptor<IPluginManagementService>(
  ServiceChannels.PluginManagement,
);
