/*
 * Row ordering. Codex assigns one session_id to the whole root/subagent tree. Keep that tree
 * together in the list, but key each node by its canonical first SessionMeta.id. The first
 * bucket encounter is already the newest activity in the backend order; within it, root precedes
 * recursively nested children so parallel agents no longer look like duplicate top-level
 * conversations.
 */

/** Bucket sessions by codex thread (or standalone row) and record each bucket's newest activity. */
function bucketSessions(sessions) {
  const buckets = new Map();
  (sessions || []).forEach((session, index) => {
    const grouped = session.source === 'codex' && session.canonicalThreadIdValid && session.rootSessionId;
    // Keep live/configured/imported stores independent. A copied snapshot may share both root
    // and thread ids with a live rollout, but must never replace it merely because its copy mtime
    // is newer.
    const key = grouped
      ? `codex:${session.dirId || ''}:${session.rootSessionId}`
      : `row:${session.id || ''}:${session.file || index}`;
    if (!buckets.has(key)) buckets.set(key, { index, activity: 0, sessions: [] });
    const bucket = buckets.get(key);
    bucket.activity = Math.max(bucket.activity, session.lastActivity || 0);
    bucket.sessions.push(session);
  });
  return buckets;
}

const newest = (a, b) => (b.lastActivity || 0) - (a.lastActivity || 0)
  || (b.createdAt || 0) - (a.createdAt || 0)
  || String(a.threadId || a.id || '').localeCompare(String(b.threadId || b.id || ''))
  || String(a.file || '').localeCompare(String(b.file || ''));

/** Depth-first flatten of one codex bucket: each root, then its children, recursively. */
function flattenCodexBucket(bucket, ordered) {
  const byParent = new Map();
  bucket.sessions.forEach((session) => {
    const parent = session.parentThreadId || '';
    if (!byParent.has(parent)) byParent.set(parent, []);
    byParent.get(parent).push(session);
  });
  byParent.forEach((children) => children.sort(newest));
  const seen = new Set();
  const append = (session) => {
    const id = session.canonicalThreadIdValid
      ? (session.threadId || session.sessionId || session.id)
      : `${session.id || ''}:${session.file || ''}`;
    if (seen.has(id)) return;
    seen.add(id); ordered.push(session);
    (byParent.get(id) || []).forEach(append);
  };
  bucket.sessions
    .filter((session) => !session.isSubagent || session.threadId === session.rootSessionId)
    .sort(newest)
    .forEach(append);
  bucket.sessions.sort((a, b) => (a.agentDepth || 0) - (b.agentDepth || 0) || newest(a, b)).forEach(append);
}

export function orderSessionRows(sessions) {
  const buckets = bucketSessions(sessions);
  const ordered = [];
  [...buckets.values()].sort((a, b) => b.activity - a.activity || a.index - b.index).forEach((bucket) => {
    if (bucket.sessions.length === 1 || bucket.sessions[0].source !== 'codex') {
      ordered.push(...bucket.sessions);
      return;
    }
    flattenCodexBucket(bucket, ordered);
  });
  return ordered;
}
