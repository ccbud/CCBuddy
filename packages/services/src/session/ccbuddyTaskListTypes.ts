import type { WorkspacePurpose, CCbuddyTaskMeta } from "@ccbuddy/shared";

export type CCbuddyTaskListKind = "pinned" | "archived" | "timeline" | "active";
export type CCbuddyTaskListSortBy = "created" | "updated";

export interface CCbuddyTaskListWorkspaceScope {
  workspacePath: string;
  workspaceIdentity?: string;
  workspacePurpose?: WorkspacePurpose;
}

export interface CCbuddyTaskListQuery {
  kind: CCbuddyTaskListKind;
  workspaceScopes: CCbuddyTaskListWorkspaceScope[];
  sortBy: CCbuddyTaskListSortBy;
  search?: string;
  limit?: number;
}

export type CCbuddyTaskListItem = CCbuddyTaskMeta & {
  searchSnippet?: string;
  searchSnippets?: string[];
};

export interface CCbuddyTaskListResult {
  items: CCbuddyTaskListItem[];
  total: number;
  hasMore: boolean;
}

export type CCbuddyTaskGroupColor =
  | "gray"
  | "red"
  | "orange"
  | "yellow"
  | "green"
  | "blue"
  | "purple";

export interface CCbuddyTaskGroup {
  id: string;
  title: string;
  color: CCbuddyTaskGroupColor;
  createdAt: number;
  updatedAt: number;
}

export interface CCbuddyGroupedTaskRef {
  workspacePath: string;
  workspaceIdentity?: string;
  taskId: string;
}

export type CCbuddyGroupedTaskViewTopLevelNodeRef =
  | { type: "group"; groupId: string }
  | { type: "task"; task: CCbuddyGroupedTaskRef };

export type CCbuddyGroupedTaskViewNode =
  | {
      type: "group";
      group: CCbuddyTaskGroup;
      tasks: CCbuddyTaskListItem[];
      sortOrder?: number;
    }
  | {
      type: "task";
      task: CCbuddyTaskListItem;
      sortOrder?: number;
    };

export interface CCbuddyGroupedTaskView {
  nodes: CCbuddyGroupedTaskViewNode[];
}

export interface CCbuddyGroupedTaskViewQuery {
  workspaceScopes: CCbuddyTaskListWorkspaceScope[];
  includeAllWorkspaces?: boolean;
}

// ── grouped 原始结构（不 join tasks 表）──
// grouped 视图的任务数据源迁到 sessions-index 后，服务端只提供分组结构
// （task_groups / task_group_members / task_group_view_node_orders），
// 由客户端与 sessions-index 会话做 join。

/** 组成员引用（不含任务 meta；task 内容由 sessions-index 提供）。 */
export interface CCbuddyGroupedTaskViewStructureMember {
  groupId: string;
  /** 服务端口径 workspaceKey（resolveWorkspaceKey：identity ?? path），join 匹配键。 */
  workspaceKey: string;
  workspacePath: string;
  workspaceIdentity?: string;
  taskId: string;
  /** null = 尚未落 sort_order（新加入组）；客户端按 addedAt 降序补内存序。 */
  sortOrder: number | null;
  addedAt: number;
}

/** 顶层节点排序（task_group_view_node_orders，node_key 已解析为结构化引用）。 */
export type CCbuddyGroupedTaskViewStructureTopOrder =
  | { type: "group"; groupId: string; sortOrder: number }
  | { type: "task"; workspaceKey: string; taskId: string; sortOrder: number };

export interface CCbuddyGroupedTaskViewStructure {
  /** 已按 workspaceScopes 可见性过滤的 group（bootstrap workspace group 只在其 workspace 可见）。 */
  groups: CCbuddyTaskGroup[];
  /** 全量组成员（含不可见 group 的成员——顶层排除规则需要全量判断）。 */
  members: CCbuddyGroupedTaskViewStructureMember[];
  topLevelOrders: CCbuddyGroupedTaskViewStructureTopOrder[];
}

export interface CCbuddyGroupedTaskViewOrderInput {
  workspaceScopes: CCbuddyTaskListWorkspaceScope[];
  topLevelNodes: CCbuddyGroupedTaskViewTopLevelNodeRef[];
  groups: Array<{
    groupId: string;
    taskRefs: CCbuddyGroupedTaskRef[];
  }>;
}

export interface CCbuddyWorkspaceEventSubscriptionParams {
  workspacePath: string;
  workspaceIdentity?: string;
}
