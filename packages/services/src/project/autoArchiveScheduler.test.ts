import { expect, it, vi } from "vitest";
import {
  createTaskAutoArchiveScheduler,
  shouldRescanTaskAutoArchive,
} from "./autoArchiveScheduler.js";

it("coalesces concurrent scans, publishes only changes and stops after disposal", async () => {
  let release!: () => void;
  const first = new Promise<void>((resolve) => {
    release = resolve;
  });
  const readPolicy = vi
    .fn()
    .mockImplementationOnce(async () => {
      await first;
      return { cutoff: 100, activeTasks: [] };
    })
    .mockResolvedValue({ cutoff: 200, activeTasks: [] });
  const archived = [{ workspacePath: "/project", taskId: "old" }];
  const archiveInactive = vi.fn().mockReturnValueOnce(archived).mockReturnValue([]);
  const afterChange = vi.fn(async () => {});
  const scheduler = createTaskAutoArchiveScheduler({
    readPolicy,
    repository: async () => ({ archiveInactive }),
    afterChange,
  });
  const running = scheduler.scan();
  const queued = scheduler.scan();
  expect(scheduler.scan()).toBe(queued);
  release();
  expect(await running).toEqual(archived);
  expect(await queued).toEqual([]);
  expect(readPolicy).toHaveBeenCalledTimes(2);
  expect(afterChange).toHaveBeenCalledOnce();
  scheduler.dispose();
  expect(await scheduler.scan()).toEqual([]);
  expect(readPolicy).toHaveBeenCalledTimes(2);
  expect(shouldRescanTaskAutoArchive(["theme"])).toBe(false);
  expect(shouldRescanTaskAutoArchive(["taskAutoArchiveEnabled"])).toBe(true);
});
