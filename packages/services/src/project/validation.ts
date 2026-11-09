import { z } from "zod";
import type { Stats } from "node:fs";
import { stat } from "node:fs/promises";
import type { VirtualProject } from "./contract.js";
// Bug 原因（ZCT-2113660144497782784）：目录的 stat 可能永久不返回（例如 macOS 等待文件夹访问授权、
// 网络盘无响应）。过去每次 readTree/prepareSession 都重新 stat 并无限等待：项目树和新建任务一直不返回，
// 且每次重试再占一个 libuv 线程，4 个后进程内所有文件操作都卡住。
// 修复：同一路径上一次 stat 还没返回时复用它；从首次发起起超过截止时间仍未返回，按“无法访问”返回。
// stat 返回后立即删除记录，下一次读取重新检查，不缓存结果。
const PRIMARY_ROOT_STATUS_TIMEOUT_MS = 30_000;
const inFlightPrimaryRootStats = new Map<string, { startedAt: number; result: Promise<Stats> }>();

function startPrimaryRootStat(path: string) {
  const flight = { startedAt: Date.now(), result: stat(path) };
  const clear = () => {
    if (inFlightPrimaryRootStats.get(path) === flight) inFlightPrimaryRootStats.delete(path);
  };
  flight.result.then(clear, clear);
  inFlightPrimaryRootStats.set(path, flight);
  return flight;
}

export async function readPrimaryRootStatus(
  path: string,
): Promise<NonNullable<VirtualProject["primaryRootStatus"]>> {
  const flight = inFlightPrimaryRootStats.get(path) ?? startPrimaryRootStat(path);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<null>((resolve) => {
    timer = setTimeout(
      () => resolve(null),
      Math.max(0, flight.startedAt + PRIMARY_ROOT_STATUS_TIMEOUT_MS - Date.now()),
    );
  });
  try {
    const stats = await Promise.race([flight.result, deadline]);
    if (!stats) return "unavailable";
    return stats.isDirectory() ? "available" : "missing";
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    return code === "ENOENT" || code === "ENOTDIR" ? "missing" : "unavailable";
  } finally {
    clearTimeout(timer);
  }
}

export async function projectPrimaryRootStatuses(
  projects: VirtualProject[],
): Promise<VirtualProject[]> {
  // 主目录存在性属于文件系统事实；每次读取重新派生，不能把删除/恢复后的旧值固化进 SQLite。
  // 同一主目录的检查由 readPrimaryRootStatus 复用进行中的 stat，这里不再单独去重。
  return Promise.all(
    projects.map(async (project) => {
      const primary = project.roots.find((root) => root.isPrimary)?.rootPath;
      if (!primary || project.deleted) return project;
      return { ...project, primaryRootStatus: await readPrimaryRootStatus(primary) };
    }),
  );
}

export const saveProjectSchema = z
  .object({
    reuseExistingRoot: z.boolean().optional(),
    id: z.string().min(1).optional(),
    hostId: z.string().min(1).optional(),
    restoreProjectId: z.string().min(1).optional(),
    name: z.string().optional(),
    defaultName: z.string().optional(),
    roots: z.array(z.string().min(1)).optional(),
    primaryRoot: z.string().min(1).optional(),
    pinned: z.boolean().optional(),
  })
  .strict()
  .refine(
    (value) =>
      !value.reuseExistingRoot ||
      (value.roots?.length === 1 &&
        (!value.hostId || value.hostId === "local") &&
        Object.keys(value).every((key) => ["roots", "hostId", "reuseExistingRoot"].includes(key))),
    "project.invalid-directory-open",
  )
  .refine((value) => !(value.id && value.restoreProjectId), "project.ambiguous-save")
  .refine(
    (value) => !value.restoreProjectId || value.roots !== undefined,
    "project.restore-roots-required",
  );
