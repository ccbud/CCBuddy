import { useEffect } from "react";
import type { PluginUiInstanceDerivation } from "../domain/pluginUiInstancePolicy.js";
import {
  retainPluginUiSessionViewState,
  setPluginUiInstanceDerivation,
} from "../app/pluginUiInstanceStore.js";
import { usePluginUiSessionKey } from "./PluginUiProviders.js";

export function usePluginUiTimelineViewState(
  derivation: PluginUiInstanceDerivation,
): string | null {
  const key = usePluginUiSessionKey();
  // 修复原因：裸 sessionId 与卡片的 workspace/session key 不一致，裁决和固定偏好因此无法互读。
  // 时间线独立持有挂载 lease，确保 LRU 只淘汰闲置会话；卸载不影响页面 owner 的沙箱生命周期。
  useEffect(() => {
    if (key === null) return;
    return retainPluginUiSessionViewState(key);
  }, [key]);
  useEffect(() => {
    if (key !== null) setPluginUiInstanceDerivation(key, derivation);
  }, [derivation, key]);
  return key;
}
