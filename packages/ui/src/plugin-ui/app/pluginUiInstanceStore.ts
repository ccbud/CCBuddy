import {
  EMPTY_PLUGIN_UI_INSTANCE_DERIVATION,
  type PluginUiInstanceDerivation,
  type PluginUiRowDisposition,
} from "../domain/pluginUiInstancePolicy.js";

interface SessionViewState {
  derivation: PluginUiInstanceDerivation;
  pins: Map<string, boolean>;
  leases: Set<symbol>;
  pendingClear: boolean;
}

// 修复：原来的两个模块级 Map 在浏览/删除会话后一直持有裁决和 pins。
// 由同一有界 owner 管理二者；页面保活仍归 page manager，视图缓存淘汰不销毁沙箱。
const MAX_INACTIVE_SESSIONS = 30;
const sessions = new Map<string, SessionViewState>();
const listeners = new Set<() => void>();
const disclosureListeners = new Set<() => void>();
let disclosureVersion = 0;

function touch(sessionKey: string): SessionViewState {
  const state = sessions.get(sessionKey) ?? {
    derivation: EMPTY_PLUGIN_UI_INSTANCE_DERIVATION,
    pins: new Map<string, boolean>(),
    leases: new Set<symbol>(),
    pendingClear: false,
  };
  sessions.delete(sessionKey);
  sessions.set(sessionKey, state);
  return state;
}

/** 裁决淘汰和固定偏好变化分别通知，空偏好的会话也可能持有裁决。 */
function pruneInactiveSessions(): { changed: boolean; pinsChanged: boolean } {
  let inactive = 0;
  for (const state of sessions.values()) if (!state.leases.size) inactive++;
  let pinsChanged = false;
  let changed = false;
  for (const [key, state] of sessions) {
    if (inactive <= MAX_INACTIVE_SESSIONS) break;
    if (state.leases.size) continue;
    sessions.delete(key);
    changed = true;
    inactive--;
    pinsChanged ||= state.pins.size > 0;
  }
  return { changed, pinsChanged };
}

function notify(pinsChanged: boolean): void {
  if (pinsChanged) {
    disclosureVersion++;
    for (const listener of disclosureListeners) listener();
  }
  for (const listener of listeners) listener();
}

export function retainPluginUiSessionViewState(sessionKey: string): () => void {
  const state = touch(sessionKey);
  const lease = Symbol();
  state.leases.add(lease);
  return () => {
    // StrictMode 重挂、多个时间线及任务移除后的迟到 cleanup 只能释放捕获的原 lease。
    if (sessions.get(sessionKey) !== state || !state.leases.delete(lease)) return;
    if (!state.leases.size) {
      if (state.pendingClear) {
        clearPluginUiSessionViewState(sessionKey);
        return;
      }
      touch(sessionKey);
      const evicted = pruneInactiveSessions();
      if (evicted.changed) notify(evicted.pinsChanged);
    }
  };
}

/** 有挂载 lease 时延迟到最后释放，避免未变化的投影失去已经发布的裁决。 */
export function clearPluginUiSessionViewState(sessionKey: string): void {
  const state = sessions.get(sessionKey);
  if (!state) return;
  // 页面可因离屏容量回收先于时间线移除，rows 不变时发布 effect 不会重跑。
  // 保留现有裁决及偏好，最后一次释放再一起清理；不能先清空再等待下一次投影。
  if (state.leases.size) {
    state.pendingClear = true;
    return;
  }
  const pinsChanged = state.pins.size > 0;
  const changed = pinsChanged || state.derivation !== EMPTY_PLUGIN_UI_INSTANCE_DERIVATION;
  sessions.delete(sessionKey);
  if (changed) notify(pinsChanged);
}

export function setPluginUiInstanceDerivation(
  sessionKey: string,
  derivation: PluginUiInstanceDerivation,
): void {
  const state = touch(sessionKey);
  const unchanged = state.derivation === derivation;
  state.derivation = derivation;
  const evicted = pruneInactiveSessions();
  if (!unchanged || evicted.changed) notify(evicted.pinsChanged);
}

export function getPluginUiRowDisposition(
  sessionKey: string,
  toolCallId: string,
): PluginUiRowDisposition | undefined {
  return sessions.get(sessionKey)?.derivation.byToolCallId[toolCallId];
}

export function getPluginUiManualPin(sessionKey: string, toolCallId: string): boolean | undefined {
  return sessions.get(sessionKey)?.pins.get(toolCallId);
}

export function setPluginUiManualPin(
  sessionKey: string,
  toolCallId: string,
  pinned: boolean | undefined,
): void {
  if (getPluginUiManualPin(sessionKey, toolCallId) === pinned) return;
  const state = touch(sessionKey);
  if (pinned === undefined) state.pins.delete(toolCallId);
  else state.pins.set(toolCallId, pinned);
  pruneInactiveSessions();
  notify(true);
}

export function getPluginUiDisclosureVersion(): number {
  return disclosureVersion;
}

export function subscribePluginUiDisclosure(listener: () => void): () => void {
  disclosureListeners.add(listener);
  return () => disclosureListeners.delete(listener);
}

export function subscribePluginUiInstances(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** 测试用：清空全部记录。 */
export function resetPluginUiInstancesForTest(): void {
  sessions.clear();
  listeners.clear();
  disclosureListeners.clear();
  disclosureVersion = 0;
}
