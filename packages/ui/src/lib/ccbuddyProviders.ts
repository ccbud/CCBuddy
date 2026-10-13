import {
  CCBUDDY_AGENT_PROVIDER,
  CCBUDDY_AGENT_PROVIDER_LABEL,
  type CCbuddyProvider,
} from "@ccbuddy/shared";

export const CCBUDDY_AGENT_PROVIDERS: CCbuddyProvider[] = [CCBUDDY_AGENT_PROVIDER];

export const CCBUDDY_AGENT_PROVIDER_LABELS: Record<CCbuddyProvider, string> = {
  glm: CCBUDDY_AGENT_PROVIDER_LABEL,
};

export function supportsCCbuddySessionFork(provider: CCbuddyProvider): boolean {
  void provider;
  // 功能开关：fork 入口恢复对所有 CCbuddy provider 开放；实际可操作性仍由 task 状态、
  // assistant 目标和运行中保护 guard 控制，避免把 active/failed 分支暴露为可 fork。
  return true;
}

export function shouldHideCCbuddySessionForkAction(provider: CCbuddyProvider): boolean {
  return !supportsCCbuddySessionFork(provider);
}
