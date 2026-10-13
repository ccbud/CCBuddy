import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { setImmediate } from "node:timers/promises";
import { Emitter } from "@ccbuddy/rpc";
import {
  CCBUDDY_PROTOCOL_NAME,
  CCBUDDY_PROTOCOL_VERSION,
  ccbuddySessionEventSchema,
  ccbuddySessionStateSnapshotSchema,
  type CCbuddySessionStateSnapshot,
  type CCbuddyStreamEvent,
} from "@ccbuddy/shared";
import { getLegacyTaskSessionSnapshotPath, setDataBaseDir } from "../src/paths.js";
import { parseLegacyTaskSessionFile } from "../src/session/legacyTaskSessionFile.js";
import { TaskIndexRepo } from "../src/session/taskIndexRepo.js";
import { createCCbuddyTaskServiceAdapter } from "../src/ccbuddy-agent/ccbuddyTaskServiceAdapter.js";
import type { CCbuddyAgentServiceEvent } from "../src/ccbuddy-agent/ccbuddyAgent.js";

for (const clientMode of ["desktop-continuous", "web-remote-replayable"] as const) {
  for (const failsOnce of [false, true]) {
    test(`previously imported Claude history becomes a real session for ${clientMode} (${failsOnce ? "retry" : "direct"})`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "ccbuddy-import-recovery-"));
      setDataBaseDir(dir);
      const meta = {
        taskId: "claude-import-example",
        traceId: "import-trace-example",
        workspacePath: "/example/workspace",
        workspaceIdentity: "example-remote-workspace",
        title: "Imported example",
        mode: "build" as const,
        provider: "glm" as const,
        migrationSource: "claudeCode" as const,
        createdAt: 1,
        updatedAt: 2,
      };
      const legacy = parseLegacyTaskSessionFile({
        meta,
        messages: [
          { id: "old-user", role: "user", content: "Example question", timestamp: 1 },
          { id: "old-assistant", role: "assistant", content: "Example answer", timestamp: 2 },
        ],
        toolCalls: [],
      });
      const path = getLegacyTaskSessionSnapshotPath(
        meta.workspacePath,
        meta.taskId,
        meta.workspaceIdentity,
      );
      const content = JSON.stringify(legacy);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, content);
      const taskIndexRepo = new TaskIndexRepo(join(dir, "tasks.sqlite"));
      await taskIndexRepo.syncTaskMeta({ meta });
      type Options = Parameters<typeof createCCbuddyTaskServiceAdapter>[0];
      type CreateInput = Parameters<Options["ccbuddyAgentService"]["createSession"]>[0];
      type SubscribeInput = Parameters<Options["ccbuddyAgentService"]["onDynamicSessionEvent"]>[0];
      const created: CreateInput[] = [];
      const subscribed: SubscribeInput[] = [];
      const sessionEvents = new Emitter<CCbuddyAgentServiceEvent>();
      let failNextUpgrade = failsOnce;
      let session: CCbuddySessionStateSnapshot | undefined;
      const disposable = () => ({ dispose() {} });
      const service = createCCbuddyTaskServiceAdapter({
        taskIndexRepo,
        ccbuddyAgentService: {
          async resumeSession() {
            if (!session) throw new Error(`Session not found: ${meta.taskId}`);
            return session;
          },
          async createSession(input: CreateInput) {
            if (failNextUpgrade) {
              failNextUpgrade = false;
              throw new Error("Temporary upgrade failure");
            }
            created.push(input);
            session = ccbuddySessionStateSnapshotSchema.parse({
              protocol: { name: CCBUDDY_PROTOCOL_NAME, version: CCBUDDY_PROTOCOL_VERSION },
              session: {
                sessionId: input.sessionId,
                workspace: {
                  workspacePath: meta.workspacePath,
                  workspaceIdentity: meta.workspaceIdentity,
                  workspaceKey: meta.workspaceIdentity,
                },
                sessionKind: "interactive",
                title: input.importedHistory?.title,
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
            return session;
          },
          onDynamicSessionEvent(input: SubscribeInput) {
            subscribed.push(input);
            return sessionEvents.event;
          },
          disposeAll() {},
        } as unknown as Options["ccbuddyAgentService"],
        taskIndexSyncer: {
          onSessionTerminalEvent: disposable,
          onSessionReadyEvent: disposable,
          disposeAll() {},
        } as unknown as Options["taskIndexSyncer"],
      });
      try {
        if (failsOnce) {
          const legacySnapshot = await service.getTaskSnapshot({ ...meta, clientMode });
          assert.deepEqual(legacySnapshot?.messages, legacy.messages);
          const legacySubscription = service.onDynamicTaskEvent({ ...meta })(() => {});
          assert.equal(subscribed.length, 0);
          legacySubscription.dispose();
        }
        const snapshot = await service.getTaskSnapshot({ ...meta, clientMode });
        assert.equal(snapshot?.meta.taskId, meta.taskId);
        assert.equal(snapshot?.meta.migrationSource, "claudeCode");
        assert.equal(created.length, 1);
        assert.equal(created[0]?.workspaceIdentity, meta.workspaceIdentity);
        assert.equal(created[0]?.sessionId, meta.taskId);
        assert.equal(created[0]?.persistence, "immediate");
        assert.deepEqual(created[0]?.importedHistory, {
          source: "claudeCode",
          title: meta.title,
          createdAt: 1,
          updatedAt: 2,
          messages: legacy.messages.map(({ role, content, timestamp }) => ({
            role,
            content,
            timestamp,
          })),
        });
        assert.equal(await readFile(path, "utf8"), content);

        const received: CCbuddyStreamEvent[] = [];
        const subscription = service.onDynamicTaskEvent({
          ...meta,
          deliveryKind: clientMode === "web-remote-replayable" ? "replayable" : "continuous",
        })((event) => received.push(event));
        try {
          assert.equal(subscribed.length, 1);
          assert.equal(subscribed[0]?.deliveryKind, clientMode);
          assert.equal(subscribed[0]?.includeSnapshot, clientMode === "web-remote-replayable");
          sessionEvents.fire({
            type: "session.event",
            event: ccbuddySessionEventSchema.parse({
              eventId: "upgraded-turn-completed",
              seq: 1,
              sessionId: meta.taskId,
              turnId: "upgraded-turn",
              type: "turn.completed",
              timestamp: 3,
              payload: {
                response: "Continued answer",
                tokenCount: 1,
                toolCallCount: 0,
                duration: 1,
                resultType: "success",
              },
            }),
          });
          assert.deepEqual(
            received.map((event) => event.type),
            ["agent_message_chunk", "task_complete"],
          );
          assert.equal(
            received.find((event) => event.type === "agent_message_chunk")?.content,
            "Continued answer",
          );
          await setImmediate();
          assert.equal((await taskIndexRepo.getTaskMeta(meta))?.status, "completed");
        } finally {
          subscription.dispose();
        }
      } finally {
        service.disposeAll();
        sessionEvents.dispose();
        taskIndexRepo.close();
        setDataBaseDir(null);
        await rm(dir, { recursive: true, force: true });
      }
    });
  }
}
