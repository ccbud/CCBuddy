import type { CCbuddyBackgroundTaskControlItem } from "./background-task-controls.js";

export function mergeCCbuddyBackgroundTaskControlItems(
  current: readonly CCbuddyBackgroundTaskControlItem[],
  updates: readonly CCbuddyBackgroundTaskControlItem[],
): CCbuddyBackgroundTaskControlItem[] {
  const jobsById = new Map(current.map((job) => [job.jobId, job] as const));
  for (const job of updates) {
    jobsById.set(job.jobId, job);
  }
  return Array.from(jobsById.values());
}
