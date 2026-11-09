import type { DatabaseSync } from "node:sqlite";

export function createLegacyDatabase(db: DatabaseSync): void {
  db.exec(`CREATE TABLE tasks (
    workspace_key TEXT NOT NULL, workspace_path TEXT NOT NULL, workspace_identity TEXT,
    task_id TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', task_status TEXT, provider TEXT,
    mode TEXT NOT NULL DEFAULT 'build', model TEXT, migration_source TEXT, forked_from_task_id TEXT,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, unread_at INTEGER,
    last_unread_at INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0,
    title_overridden INTEGER NOT NULL DEFAULT 0, searchable_text TEXT NOT NULL DEFAULT '',
    cron_automation_id TEXT, off_peak_task_id TEXT, meta_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY(workspace_key,task_id));
    CREATE TABLE task_groups (group_id TEXT PRIMARY KEY, title TEXT NOT NULL);
    CREATE TABLE task_group_members (group_id TEXT,workspace_key TEXT,task_id TEXT);
    CREATE TABLE task_group_view_node_orders (node_type TEXT,node_key TEXT,sort_order INTEGER);
    CREATE TABLE task_group_workspace_bootstraps (workspace_key TEXT PRIMARY KEY,group_id TEXT);`);
}
