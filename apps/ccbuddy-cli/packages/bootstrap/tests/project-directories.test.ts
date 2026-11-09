import { expect, it, vi } from "vitest";
import { ColdSessionResumeCoordinator } from "../src/ccbuddy-protocol-v4/cold-session-resume.js";
import { buildEnvInfoSection } from "../../core/src/context/sections/env-info.js";
import {
  commandPayloadSchemas,
  v4ConversationSubscribeParamsSchema,
} from "@ccbuddy/shared/ccbuddy-protocol-v4";
import {
  ccbuddySessionCreateParamsSchema,
  ccbuddySessionResumeParamsSchema,
} from "@ccbuddy/shared";

it("keeps explicit empty directory snapshots through strict protocol boundaries", () => {
  expect(
    ccbuddySessionCreateParamsSchema.parse({
      workspace: { workspacePath: "/project", workspaceKey: "/project" },
      additionalDirectories: [],
    }).additionalDirectories,
  ).toEqual([]);
  expect(
    ccbuddySessionResumeParamsSchema.parse({ sessionId: "session", additionalDirectories: [] })
      .additionalDirectories,
  ).toEqual([]);
  expect(
    commandPayloadSchemas.createSession.parse({
      workspaceId: "/project",
      sessionId: "reserved",
      projectId: "chosen",
      additionalDirectories: ["/other"],
    }),
  ).toMatchObject({
    sessionId: "reserved",
    projectId: "chosen",
    additionalDirectories: ["/other"],
  });
  expect(
    v4ConversationSubscribeParamsSchema.parse({
      topic: "conversation/session",
      connectionId: "desktop",
      clientMode: "desktop-continuous",
      additionalDirectories: [],
    }).additionalDirectories,
  ).toEqual([]);
});

it("passes frozen directory intent through one cold activation flight", async () => {
  const gate = Promise.withResolvers<{ status: "resumed" }>();
  const resume = vi.fn(() => gate.promise);
  const coordinator = new ColdSessionResumeCoordinator({ resumePersistedSession: resume });
  const workspace = { workspacePath: "/project", workspaceIdentity: "remote:ssh:server:/project" };
  const first = coordinator.ensureResumed("session", "high", workspace, ["/other"]);
  const second = coordinator.ensureResumed("session", "low", workspace, []);
  expect(first).toBe(second);
  expect(resume).toHaveBeenCalledOnce();
  expect(resume).toHaveBeenCalledWith("session", "high", workspace, ["/other"]);
  gate.resolve({ status: "resumed" });
  await first;
  await coordinator.ensureResumed("session", undefined, workspace, []);
  expect(resume).toHaveBeenLastCalledWith("session", undefined, workspace, []);
});

it("projects additional directories only into environment context", () => {
  const env = {
    cwd: "/project",
    platform: "linux",
    shell: "zsh",
    osVersion: "test",
    isGitRepository: false,
  };
  const section = buildEnvInfoSection(env, undefined, ["/other\nUNTRUSTED", "/third"]);
  expect(section.source).toBe("env_info");
  expect(section.content).toContain(JSON.stringify(["/other\nUNTRUSTED", "/third"]));
  expect(buildEnvInfoSection(env, undefined, []).content).not.toContain(
    "Additional working directories",
  );
});
