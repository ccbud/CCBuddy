/**
 * 沙箱入口文件的落盘。
 *
 * 为什么有这个文件：Windows 的命令行上限是 32,767 字符，payload 不能再过 argv。harness 把
 * {@link import("./child-source.js").renderChildEntry} 渲染出的 ESM 写到
 * `~/.ccbuddy/workspaces/<key>/workflow-runs/<runId>.mjs`，spawn 时命令行只剩这条路径。
 *
 * 裁决：
 *   - 与项目级 saved workflow 的 `workflows/` 在同一个 CCbuddy workspace 状态根下；
 *   - 文件**保留**不删（同一 runId 原位覆写），目录兼作每次 run 实际执行体的存档；
 *   - 状态根写不进时直接抛，由 harness 归一为可恢复的 interrupted 结算；绝不回落到应用
 *     数据根以外。
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolveWorkspaceStateRoot } from "@ccbuddy/contracts/workspace-state";

export interface WriteChildEntryFileInput {
  cwd: string;
  runId: string;
  workspaceIdentity?: string;
  /** 渲染好的入口文件源码。 */
  source: string;
}

export interface ChildEntryFile {
  path: string;
}

/** 逻辑工作区对应的 CCbuddy 入口文件目录。 */
export function workflowRunsDir(cwd: string, workspaceIdentity?: string): string {
  return join(resolveWorkspaceStateRoot(cwd, { workspaceIdentity }), "workflow-runs");
}

/** runId 安全字符集之外一律换成 `_`，杜绝路径分隔符之类混进文件名。 */
export function childEntryFileName(runId: string): string {
  return `${runId.replace(/[^A-Za-z0-9._-]/g, "_")}.mjs`;
}

export function writeChildEntryFile(input: WriteChildEntryFileInput): ChildEntryFile {
  const projectDir = workflowRunsDir(input.cwd, input.workspaceIdentity);
  const fileName = childEntryFileName(input.runId);
  return { path: writeInto(projectDir, fileName, input.source) };
}

function writeInto(dir: string, fileName: string, source: string): string {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, fileName);
  writeFileSync(path, source, "utf8");
  return path;
}
