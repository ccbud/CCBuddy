import type { ModelSelection } from "@ccbuddy/contracts";
import type { PresentationSurface } from "@ccbuddy/core";
import type { CCbuddyAppOptions } from "../app/types.js";

export function applyProtocolPresentationSurface(
  options: Omit<CCbuddyAppOptions, "providerRegistry">,
  presentationSurface: PresentationSurface,
): Omit<CCbuddyAppOptions, "providerRegistry"> {
  return {
    ...options,
    runtimeConfig: {
      ...options.runtimeConfig,
      presentationSurface,
    },
  };
}

/**
 * 进程级 Registry 已就绪后，它就是当前 Environment 的模型事实源。
 *
 * 旧 workspace snapshot 不再参与 Provider 和 Model 执行。
 */
export function applyProtocolProviderRegistry(
  options: Omit<CCbuddyAppOptions, "providerRegistry">,
  providerRegistry: CCbuddyAppOptions["providerRegistry"],
  configuredDefaultModelSelection?: ModelSelection,
): CCbuddyAppOptions {
  return {
    ...options,
    providerRegistry,
    ...(configuredDefaultModelSelection ? { configuredDefaultModelSelection } : {}),
  };
}
