import { useEffect, useMemo, useState } from "react";
import type { V4ConversationWorkflowRunNodeResultResult } from "@ccbuddy/shared/ccbuddy-protocol-v4";
import { logger } from "@/logger.js";
import { useV4Conversation } from "@/v4/V4ConversationContext.js";

/**
 * 一个工作区节点的正文：卡片展开时才取，
 * 取回后按 (会话, run, 站点@序号) 缓存——收起再展开不重读，同一 run 的另一份 tab 也复用。
 *
 * 缓存只收**已结算**的行：结算后的 journal 行不再改写，所以缓存永不过期；running 行没有正文，
 * 也就没有可缓存的东西。上限 256 条，满了丢最早的——一个 32 KB 上界的正文乘 256 是 8 MB，
 * 这是渲染进程愿意为「秒开」付的钱。
 */

const CACHE_CAP = 256;
const cache = new Map<string, V4ConversationWorkflowRunNodeResultResult>();

function cacheKey(sessionId: string, runId: string, siteId: string, ordinal: number): string {
  return `${sessionId}\u0000${runId}\u0000${siteId}@${ordinal}`;
}

function remember(key: string, value: V4ConversationWorkflowRunNodeResultResult): void {
  if (cache.size >= CACHE_CAP) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, value);
}

interface WorkflowRunNodeResultState {
  result: V4ConversationWorkflowRunNodeResultResult | null;
  loading: boolean;
  error: string | null;
}

export function useWorkflowRunNodeResult(options: {
  sessionId: string;
  runId: string;
  siteId: string;
  ordinal: number;
  /** 关掉即不读（收起的卡、running 的行）。 */
  enabled?: boolean;
}): WorkflowRunNodeResultState {
  const { workflowRunNodeResult } = useV4Conversation();
  const { ordinal, runId, sessionId, siteId } = options;
  const key = cacheKey(sessionId, runId, siteId, ordinal);
  const enabled =
    options.enabled !== false && sessionId.length > 0 && runId.length > 0 && siteId.length > 0;
  const [state, setState] = useState<WorkflowRunNodeResultState>(() => ({
    result: cache.get(key) ?? null,
    loading: false,
    error: null,
  }));

  useEffect(() => {
    const cached = cache.get(key);
    if (cached !== undefined) {
      setState({ result: cached, loading: false, error: null });
      return;
    }
    if (!enabled) {
      setState({ result: null, loading: false, error: null });
      return;
    }
    let alive = true;
    setState({ result: null, loading: true, error: null });
    void (async () => {
      try {
        const result = await workflowRunNodeResult({ sessionId, runId, siteId, ordinal });
        if (!alive) return;
        if (result.status !== "running") remember(key, result);
        setState({ result, loading: false, error: null });
      } catch (caught) {
        if (!alive) return;
        const message = caught instanceof Error ? caught.message : String(caught);
        logger.warn("[workflow-workspace] 读取节点正文失败", {
          error: message,
          ordinal,
          runId,
          sessionId,
          siteId,
        });
        setState({ result: null, loading: false, error: message });
      }
    })();
    return () => {
      alive = false;
    };
  }, [enabled, key, ordinal, runId, sessionId, siteId, workflowRunNodeResult]);

  return useMemo(() => state, [state]);
}
