import type { DatabaseSync } from "node:sqlite";
import type { SessionId, SessionTaskType } from "@ccbuddy/contracts";

export function softDeleteSession(
  db: DatabaseSync,
  sessionID: SessionId,
  timeDeleted: number,
): void {
  // 软删除保持幂等，并保留 message/part 及活动时间；旧 create/upsert 不能清除此字段。
  db.prepare("update session set time_deleted = coalesce(time_deleted, ?) where id = ?").run(
    timeDeleted,
    sessionID,
  );
}

/**
 * 只沿「附属会话」展开后代：subagent / workflow / 侧边问答的子会话随父会话存在。
 * fork 的 parent_id 也指向源会话，但它是用户可见的独立任务（可能已归入别的项目），
 * 删除源会话时绝不能连带删除；interactive / workflow_parent 同理不展开。
 */
const OWNED_CHILD_TASK_TYPES: readonly SessionTaskType[] = [
  "selection_side_chat",
  "workflow_child",
  "subagent_child",
  "nested_workflow_child",
];
const SQL_ID_CHUNK = 400;

function chunked<T>(items: readonly T[]): T[][] {
  const chunks: T[][] = [];
  for (let index = 0; index < items.length; index += SQL_ID_CHUNK)
    chunks.push(items.slice(index, index + SQL_ID_CHUNK));
  return chunks;
}

/** 每个根会话 → 根自身与全部附属后代；根不存在时返回空数组。 */
export function listOwnedSessionTrees(
  db: DatabaseSync,
  sessionIDs: readonly SessionId[],
): Map<SessionId, SessionId[]> {
  const exists = db.prepare("select 1 from session where id = ?");
  const children = db.prepare(
    `select id from session where parent_id = ? and task_type in (${OWNED_CHILD_TASK_TYPES.map(() => "?").join(",")})
     union select child_session_id as id from session_task_link where parent_session_id = ?`,
  );
  const trees = new Map<SessionId, SessionId[]>();
  for (const root of sessionIDs) {
    if (!exists.get(root)) {
      trees.set(root, []);
      continue;
    }
    const seen = new Set<SessionId>([root]);
    const queue = [root];
    while (queue.length) {
      const current = queue.shift()!;
      for (const row of children.all(current, ...OWNED_CHILD_TASK_TYPES, current) as Array<{
        id: SessionId;
      }>) {
        if (seen.has(row.id)) continue;
        seen.add(row.id);
        queue.push(row.id);
      }
    }
    trees.set(root, [...seen]);
  }
  return trees;
}

const ARTIFACT_URI_SCHEME = "ccbuddy-artifact://";
const ARTIFACT_URI_SESSION = /ccbuddy-artifact:\/\/([^/"\\\s]+)\//g;

/**
 * 每个目标会话 → 仍引用其附件（`ccbuddy-artifact://<目标>/…`）的其他未删除会话。
 * fork、回退与工作流转录按值复制 part，URI 仍指向源会话的附件目录；按 part 内容判定，
 * 不依赖 fork 谱系，任何复制路径都能覆盖。只在彻底删除时调用，一次全表扫描可接受。
 */
export function listArtifactReferrers(
  db: DatabaseSync,
  sessionIDs: readonly SessionId[],
): Map<SessionId, SessionId[]> {
  const targets = new Set<string>(sessionIDs);
  const referrers = new Map<SessionId, Set<SessionId>>();
  if (!targets.size) return new Map();
  const rows = db
    .prepare(
      `select p.session_id, p.data from part p join session s on s.id = p.session_id
       where s.time_deleted is null and instr(p.data, ?) > 0`,
    )
    .iterate(ARTIFACT_URI_SCHEME) as Iterable<{ session_id: SessionId; data: string }>;
  for (const row of rows) {
    for (const match of row.data.matchAll(ARTIFACT_URI_SESSION)) {
      const target = decodeURIComponent(match[1]!) as SessionId;
      if (target === row.session_id || !targets.has(target)) continue;
      referrers.set(target, (referrers.get(target) ?? new Set()).add(row.session_id));
    }
  }
  return new Map([...referrers].map(([target, ids]) => [target, [...ids]]));
}

/**
 * 彻底删除会话及其附属后代的全部行。message/part/todo/usage 等经外键级联；
 * input_history、dwf_run、workflow_run 对 session 没有级联外键，必须显式删除，否则留下孤儿行。
 * 调用方负责先删除会话文件：文件失败时不调用本函数，下次重试仍能按会话找到它们。
 */
export function purgeSessions(db: DatabaseSync, sessionIDs: readonly SessionId[]): void {
  const ids = [...new Set([...listOwnedSessionTrees(db, sessionIDs).values()].flat())];
  if (!ids.length) return;
  // foreign_keys 不能在事务内切换；启动时已打开，这里再保证一次级联生效。
  db.exec("pragma foreign_keys = on");
  db.exec("begin immediate");
  try {
    for (const chunk of chunked(ids)) {
      const marks = chunk.map(() => "?").join(",");
      db.prepare(`delete from input_history where session_id in (${marks})`).run(...chunk);
      db.prepare(`delete from dwf_run where parent_session_id in (${marks})`).run(...chunk);
      db.prepare(`delete from workflow_run where parent_session_id in (${marks})`).run(...chunk);
      db.prepare(`delete from session where id in (${marks})`).run(...chunk);
    }
    db.exec("commit");
  } catch (error) {
    db.exec("rollback");
    throw error;
  }
}
