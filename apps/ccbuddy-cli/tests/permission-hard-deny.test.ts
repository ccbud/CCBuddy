import assert from "node:assert/strict";
import { test } from "node:test";
import { PermissionService, defaultPermissionConfig } from "../packages/core/src/permission/service.js";
import { resolveBashPermissionRulePolicy } from "../packages/core/src/tool/handlers/bash-command-permission-policy.js";
import { resolveToolPermission } from "../packages/core/src/tool/executor/permission-flow.js";

const bashCapability = {
  destructive: false,
  needsApproval: true,
  readOnly: false,
  riskLevel: "medium" as const,
  sideEffectScope: "workspace" as const,
};

function permissionService(disallowedTools: string[] = []) {
  return new PermissionService({
    ...defaultPermissionConfig,
    allowedTools: new Set(),
    disallowedTools: new Set(disallowedTools),
  });
}

test("explicitly disabled tools stay denied in every permission mode", () => {
  const service = permissionService(["Bash", "EnterPlanMode"]);
  for (const mode of ["build", "edit", "plan", "yolo"] as const) {
    const deniedBash = service.checkPermission(
      { toolName: "Bash", input: { command: "echo ready" }, riskLevel: "medium", mode },
      bashCapability,
    );
    assert.equal(deniedBash.decision, "deny", mode);
    assert.equal(deniedBash.ruleId, "rule.disallowedTools", mode);

    const deniedTransition = service.checkPermission({
      toolName: "EnterPlanMode",
      input: {},
      riskLevel: "low",
      mode,
    });
    assert.equal(deniedTransition.decision, "deny", mode);
    assert.equal(deniedTransition.ruleId, "rule.disallowedTools", mode);
  }
});

test("a Bash deny prefix blocks a matching command inside a static compound call in yolo", () => {
  const command = "git status && git push origin main";
  const rules = {
    version: 1 as const,
    allow: [{ toolName: "Bash", ruleContent: "git push:*" }],
    deny: [{ toolName: "Bash", ruleContent: "git push:*" }],
  };
  const decision = permissionService().checkPermission(
    { toolName: "Bash", input: { command }, riskLevel: "medium", mode: "yolo" },
    bashCapability,
    rules,
    resolveBashPermissionRulePolicy({ command }),
  );
  assert.equal(decision.decision, "deny");
  assert.equal(decision.ruleId, "rule.project.deny");
});

test("project deny outranks interaction prompts and prior session grants", () => {
  const service = permissionService();
  service.grantSessionPermission([
    { type: "addRules", behavior: "allow", rules: [{ toolName: "RiskyAction" }] },
  ]);
  const decision = service.checkPermission(
    { toolName: "RiskyAction", input: {}, riskLevel: "high", mode: "yolo" },
    {
      alwaysAsk: true,
      requiresUserInteraction: true,
      riskLevel: "high",
      sideEffectScope: "userInteraction",
    },
    { version: 1, deny: [{ toolName: "RiskyAction" }] },
  );
  assert.equal(decision.decision, "deny");
  assert.equal(decision.ruleId, "rule.project.deny");
});

test("nonmatching deny leaves yolo unchanged and project ask still prompts in build", () => {
  const command = "git status";
  const rules = {
    version: 1 as const,
    deny: [{ toolName: "Bash", ruleContent: "git push:*" }],
    ask: [{ toolName: "Bash", ruleContent: "git status:*" }],
  };
  const policy = resolveBashPermissionRulePolicy({ command });
  const service = permissionService();
  assert.equal(
    service.checkPermission(
      { toolName: "Bash", input: { command }, riskLevel: "medium", mode: "yolo" },
      bashCapability,
      rules,
      policy,
    ).decision,
    "allow",
  );
  const build = service.checkPermission(
    { toolName: "Bash", input: { command }, riskLevel: "medium", mode: "build" },
    bashCapability,
    rules,
    policy,
  );
  assert.equal(build.decision, "ask");
  assert.equal(build.ruleId, "rule.project.ask");
});

test("a hard-denied call never reaches the approval broker", async () => {
  const events: { type: string; payload?: { reason?: string } }[] = [];
  let brokerCalls = 0;
  const command = "git push origin main";
  const deps = {
    emitEvent: async (event: { type: string; payload?: { reason?: string } }) => {
      events.push(event);
    },
    getWorkingDirectory: () => "/work/example",
    getWorkspaceRoot: () => "/work/example",
    permissionBroker: {
      requestPermission: async () => {
        brokerCalls += 1;
        return { decision: "allow" as const };
      },
    },
    permissionService: permissionService(),
    runtimeScope: "main",
    sessionId: "session_test",
    sessionStore: {
      getSession: async () => ({ projectID: "project_test" }),
      getProjectPermission: async () => ({
        version: 1 as const,
        deny: [{ toolName: "Bash", ruleContent: "git push:*" }],
      }),
    },
    workspaceIdentity: "local:/work/example",
  } as unknown as Parameters<typeof resolveToolPermission>[0];
  const toolCall = {
    id: "tool_test",
    name: "Bash",
    input: { command },
  } as Parameters<typeof resolveToolPermission>[1];
  const entry = {
    metadata: { name: "Bash", ...bashCapability },
    resolvePermissionRulePolicy: (input: unknown) => resolveBashPermissionRulePolicy(input),
  } as Parameters<typeof resolveToolPermission>[2];
  const result = await resolveToolPermission(
    deps,
    toolCall,
    entry,
    toolCall.input,
    { additionalContexts: [], permissionBehavior: "allow" },
    "yolo",
    { traceId: "trace_test" } as Parameters<typeof resolveToolPermission>[6],
  );
  assert.equal(result.allowed, false);
  assert.equal(brokerCalls, 0);
  assert.equal(events.length, 1);
  assert.equal(events[0]?.type, "permission_denied");
  assert.match(events[0]?.payload?.reason ?? "", /denied by project permission rules/);
});
