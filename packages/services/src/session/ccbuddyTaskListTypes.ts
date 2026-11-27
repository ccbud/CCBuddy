import type { WorkspacePurpose, CCbuddyTaskMeta } from "@ccbuddy/shared";

export type CCbuddyTaskListKind = "pinned" | "archived" | "timeline" | "active";
export type CCbuddyTaskListSortBy = "created" | "updated";

export interface CCbuddyTaskListWorkspaceScope {
  workspacePath: string;
  workspaceIdentity?: string;
  workspacePurpose?: WorkspacePurpose;
}

export interface CCbuddyTaskListQuery {
  kind: CCbuddyTaskListKind | "all";
  /** host 由存储 owner 确定全部范围，不接受 UI 已打开工作区作为历史目录。 */
  workspaceScopes: CCbuddyTaskListWorkspaceScope[] | "host";
  sortBy: CCbuddyTaskListSortBy;
  search?: string;
  limit?: number;
  /** 只返回这些会话（例如分享管理按来源会话 ID 解析跳转目标）；空数组返回空结果。 */
  taskIds?: readonly string[];
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

export interface CCbuddyWorkspaceEventSubscriptionParams {
  workspacePath: string;
  workspaceIdentity?: string;
}
