import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { createProjectId, createSessionId } from "@ccbuddy/contracts";
import { createSqliteSessionStore } from "../src/storage/session-store/sqlite-session-store.js";

it("separates archive, soft delete, owned descendants and independent forks across restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-session-data-"));
  const dbPath = join(root, "session.sqlite");
  let store = await createSqliteSessionStore({ dbPath });
  const parent = createSessionId("parent");
  const child = createSessionId("child");
  const fork = createSessionId("fork");
  const projectID = createProjectId("project");
  const input = { projectID, slug: "session", directory: root, title: "Task", version: "2.0.12" };
  try {
    await store.createSession({ ...input, id: parent });
    await store.createSession({
      ...input,
      id: child,
      parentID: parent,
      taskType: "subagent_child",
    });
    await store.createSession({ ...input, id: fork, parentID: parent, taskType: "interactive" });
    await store.updateSession({ id: parent, timeArchived: 10, lastOutcome: "interrupted" });
    expect(
      (await store.listSessions({ includeArchived: true })).map((session) => session.id),
    ).toContain(parent);
    await store.softDeleteSession(parent, 20);
    await store.softDeleteSession(parent, 30);
    expect(
      (await store.listSessions({ includeArchived: true })).map((session) => session.id),
    ).not.toContain(parent);
    expect(await store.getSession(parent)).toMatchObject({
      lastOutcome: "interrupted",
      time: { archived: 10, deleted: 20 },
    });
    store.close();
    store = await createSqliteSessionStore({ dbPath });
    expect((await store.listOwnedSessionTrees([parent])).get(parent)).toEqual([parent, child]);
    await store.purgeSessions([parent]);
    expect(await store.getSession(parent)).toBeNull();
    expect(await store.getSession(child)).toBeNull();
    expect(await store.getSession(fork)).not.toBeNull();
    await store.purgeSessions([parent]);
  } finally {
    store.close();
    await rm(root, { recursive: true, force: true });
  }
});
