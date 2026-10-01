import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  buildRemoteWorkspaceIdentity,
  CCBUDDY_PROTOCOL_NAME,
  CCBUDDY_PROTOCOL_VERSION,
  ccbuddySessionStateSnapshotSchema,
  createSessionTraceId,
  resolveWorkspaceKey,
  type CCbuddySessionStateSnapshot,
} from "@ccbuddy/shared";
import { createCCbuddyTaskServiceAdapter } from "../src/ccbuddy-agent/ccbuddyTaskServiceAdapter.js";
import { setDataBaseDir } from "../src/paths.js";
import { buildImportedHistoryTaskId } from "../src/session/history-import/historyImportTaskId.js";
import { TaskIndexRepo } from "../src/session/taskIndexRepo.js";

const source = {
  producer: "codex" as const,
  producerSessionId: "producer-session",
  workspacePath: "/workspace/project",
};
const identities = ["history-test-a", "history-test-b"].map((container) =>
  buildRemoteWorkspaceIdentity(source.workspacePath, { kind: "docker", container }),
);
const identityA = identities[0]!;
const identityB = identities[1]!;

test("history import preserves existing local IDs without a nonblank identity", () => {
  const previousLocalId = "history-import-00f9084582ce55878e90aa0f";
  assert.equal(buildImportedHistoryTaskId(source), previousLocalId);
  const blankIdentity = { ...source, workspaceIdentity: " \t " };
  assert.equal(buildImportedHistoryTaskId(blankIdentity), previousLocalId);
});

test("history import uses the trimmed identity independently of the file-operation path", () => {
  const original = { ...source, workspaceIdentity: identityA };
  const sameWorkspace = {
    ...source,
    workspaceIdentity: ` ${identityA} `,
    workspacePath: "/workspace/alternate-path",
  };
  assert.equal(buildImportedHistoryTaskId(original), buildImportedHistoryTaskId(sameWorkspace));
});

test("history import isolates different workspace identities sharing a path", () => {
  const first = { ...source, workspaceIdentity: identityA };
  const second = { ...source, workspaceIdentity: identityB };
  assert.notEqual(buildImportedHistoryTaskId(first), buildImportedHistoryTaskId(second));
});

test("imported tasks keep separate model routes after both workspaces are loaded", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ccbuddy-history-identity-"));
  setDataBaseDir(dir);
  const taskIndexRepo = new TaskIndexRepo(join(dir, "tasks.sqlite"));
  type Options = Parameters<typeof createCCbuddyTaskServiceAdapter>[0];
  type AgentService = Options["ccbuddyAgentService"];
  type CreateInput = Parameters<AgentService["createSession"]>[0];
  type SetModelInput = Parameters<AgentService["setModel"]>[0];
  const created: CreateInput[] = [];
  const modelWrites: SetModelInput[] = [];
  const sessions = new Map<string, CCbuddySessionStateSnapshot>();
  const disposable = () => ({ dispose() {} });
  const service = createCCbuddyTaskServiceAdapter({
    taskIndexRepo,
    ccbuddyAgentService: {
      async createSession(input: CreateInput) {
        created.push(input);
        const snapshot = ccbuddySessionStateSnapshotSchema.parse({
          protocol: { name: CCBUDDY_PROTOCOL_NAME, version: CCBUDDY_PROTOCOL_VERSION },
          session: {
            sessionId: input.sessionId,
            workspace: {
              workspacePath: input.workspacePath,
              workspaceIdentity: input.workspaceIdentity,
              workspaceKey: resolveWorkspaceKey(input),
            },
            sessionKind: "interactive",
            title: "Imported history",
            mode: "build",
            status: "idle",
            createdAt: 1,
            updatedAt: 2,
          },
          settings: {
            model: { available: [] },
            thoughtLevel: { enabled: false, available: [] },
            mode: { current: "build" },
          },
          projection: {
            sessionId: input.sessionId,
            status: "idle",
            mode: "build",
            turnCount: 0,
            totalTokenCount: 0,
            contextUsed: 0,
            contextWindow: 200000,
            pendingPermissions: [],
            activeToolCalls: [],
            backgroundJobs: [],
          },
          runtime: { eventSeq: 0, stateRevision: 0, pendingRequestIds: [] },
          messages: [],
        });
        sessions.set(snapshot.session.sessionId, snapshot);
        return snapshot;
      },
      async setModel(input: SetModelInput) {
        modelWrites.push(input);
      },
      async resumeSession(input: Parameters<AgentService["resumeSession"]>[0]) {
        const snapshot = sessions.get(input.sessionId);
        assert.ok(snapshot);
        return snapshot;
      },
      disposeAll() {},
    } as unknown as AgentService,
    taskIndexSyncer: {
      onSessionTerminalEvent: disposable,
      onSessionReadyEvent: disposable,
      emitWorkspaceTaskListChanged() {},
      disposeAll() {},
    } as unknown as Options["taskIndexSyncer"],
  });
  try {
    const input = { ...source, messages: [{ role: "user" as const, content: "Continue task" }] };
    const first = await service.importHistorySession({ ...input, workspaceIdentity: identityA });
    const second = await service.importHistorySession({ ...input, workspaceIdentity: identityB });
    const reused = await service.importHistorySession({
      ...input,
      workspaceIdentity: ` ${identityA} `,
    });
    assert.equal(reused.taskId, first.taskId);
    assert.equal(reused.reused, true);
    assert.equal(created.length, 2);
    for (const workspaceIdentity of identities) {
      await service.listTasks({ workspacePath: source.workspacePath, workspaceIdentity });
    }
    for (const task of [first, second]) {
      await service.setModel({
        taskId: task.taskId,
        traceId: createSessionTraceId(),
        modelSelection: { providerId: "test-provider", modelId: "test-model" },
      });
    }
    // 曾只按路径生成 ID，第二个 workspace 的列表刷新会覆盖第一个任务的模型命令路由。
    assert.deepEqual(
      modelWrites.map(({ workspaceIdentity }) => workspaceIdentity),
      [identityA, identityB],
    );
    assert.notEqual(first.taskId, second.taskId);
    assert.equal(sessions.size, 2);
  } finally {
    service.disposeAll();
    setDataBaseDir(null);
    await rm(dir, { recursive: true, force: true });
  }
});
