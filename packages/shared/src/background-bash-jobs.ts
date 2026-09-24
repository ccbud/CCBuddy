import {
  collectVisibleCCbuddyBackgroundTaskControlItems,
  getCCbuddyBackgroundTaskControlItemElapsedMs,
  isActiveCCbuddyBackgroundTaskControlItem,
  parseCCbuddyBackgroundTaskControlItems,
  type CCbuddyBackgroundTaskControlItem,
  type CCbuddyBackgroundTaskControlStatus,
} from "./background-task-controls.js";

export type CCbuddyBackgroundBashJobStatus = CCbuddyBackgroundTaskControlStatus;
export type CCbuddyBackgroundBashJob = CCbuddyBackgroundTaskControlItem & {
  taskKind: "bash";
};

export function parseCCbuddyBackgroundBashJobs(value: unknown): CCbuddyBackgroundBashJob[] {
  return parseCCbuddyBackgroundTaskControlItems(value).filter(isBackgroundBashJob);
}

export function isActiveCCbuddyBackgroundBashJob(job: CCbuddyBackgroundBashJob): boolean {
  return isActiveCCbuddyBackgroundTaskControlItem(job);
}

export function getCCbuddyBackgroundBashJobElapsedMs(
  job: CCbuddyBackgroundBashJob,
  now = Date.now(),
): number {
  return getCCbuddyBackgroundTaskControlItemElapsedMs(job, now);
}

export function collectVisibleCCbuddyBackgroundBashJobs(
  jobs: readonly CCbuddyBackgroundBashJob[],
  now = Date.now(),
  thresholdMs = 30_000,
): Array<CCbuddyBackgroundBashJob & { elapsedMs: number }> {
  return collectVisibleCCbuddyBackgroundTaskControlItems(jobs, now, thresholdMs) as Array<
    CCbuddyBackgroundBashJob & { elapsedMs: number }
  >;
}

function isBackgroundBashJob(
  job: CCbuddyBackgroundTaskControlItem,
): job is CCbuddyBackgroundBashJob {
  return job.taskKind === "bash";
}
