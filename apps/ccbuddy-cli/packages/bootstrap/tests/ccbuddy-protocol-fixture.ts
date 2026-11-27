import { ccbuddyProtocolMethods, type CCbuddyProtocolMessage } from "@ccbuddy/shared";
import { type ExecutionShellSelection } from "@ccbuddy/contracts";
import { CCbuddyProtocolAgentServer } from "../src/ccbuddy-protocol/server.js";
import type { CCbuddyApp, CCbuddyAppOptions } from "../src/app/types.js";
import { answerReplyLanguageRequest } from "./helpers/fake-host-requests.js";
import { createFakeApp } from "./helpers/fake-ccbuddy-app.js";

export const workspace = {
  workspacePath: "/workspace/app",
  workspaceKey: "/workspace/app",
};

export async function requestResult(
  server: CCbuddyProtocolAgentServer,
  message: CCbuddyProtocolMessage,
) {
  const response = await server.handleMessage(message);
  if (!response || !("result" in response)) {
    throw new Error(`Expected protocol success response: ${JSON.stringify(response)}`);
  }
  return response.result;
}

export function attachSessionRuntimePreferencesResponder(
  server: CCbuddyProtocolAgentServer,
  resolvePreferences: (scope: "runtime-materialization" | "user-execution") => {
    nativeSearchEnhancementsEnabled: boolean;
    toolSearchMode?: "auto" | "local" | "off";
    totalTokensReminderEnabled?: boolean;
    agentAlwaysBackgroundEnabled?: boolean;
    memoryEnabled?: boolean;
    subagentRuntimeConfigEnabled?: boolean;
    modelContextBudgetStrategy?: "legacy" | "preflight-v1";
    integratedTerminalShell?:
      | {
          mode: "auto";
        }
      | {
          mode: "shell";
          dialect: "git-bash" | "cmd";
          id: string;
          label: string;
          path: string;
        };
  },
): CCbuddyProtocolMessage[] {
  const requests: CCbuddyProtocolMessage[] = [];
  server.setNotificationSink((message) => {
    if (answerReplyLanguageRequest(server, message)) return;
    if (
      "id" in message &&
      message.method === ccbuddyProtocolMethods.sessionRequestRuntimePreferences
    ) {
      requests.push(message);
      const scope = (message.params as { scope: "runtime-materialization" | "user-execution" })
        .scope;
      void server.handleMessage({
        id: message.id,
        result: resolvePreferences(scope),
      });
    }
  });
  return requests;
}

export type ShellInitializationCandidate = Parameters<
  CCbuddyApp["runtime"]["initializeSessionShellEnvironmentIfNeeded"]
>[0];

export function resolveShellInitializationCandidate(
  candidate: ShellInitializationCandidate,
): ExecutionShellSelection {
  return typeof candidate === "function" ? candidate() : candidate;
}

export function createShellRecordingFakeApp(
  options: CCbuddyAppOptions,
  shellInitializations: unknown[],
  createdAppOptions?: CCbuddyAppOptions[],
): CCbuddyApp {
  createdAppOptions?.push(options);
  const app = createFakeApp(options);
  let effectiveShellSelection = options.runtimeConfig?.bashShellSelection;
  let shellInitialized = effectiveShellSelection !== undefined;
  let shellInitializationPromise: Promise<void> | undefined;
  const recordShellInitialization = (selection: ShellInitializationCandidate) => {
    if (shellInitialized) {
      return false;
    }
    const resolvedSelection = resolveShellInitializationCandidate(selection);
    effectiveShellSelection = resolvedSelection;
    shellInitialized = true;
    shellInitializations.push(resolvedSelection);
    return true;
  };
  const initializeFromStartupPreferences = async () => {
    if (shellInitialized) {
      return;
    }
    shellInitializationPromise ??= (async () => {
      const selection = await options.resolveInitialBashShellSelection?.();
      if (selection) {
        recordShellInitialization(selection);
      }
    })();
    await shellInitializationPromise;
  };
  return {
    ...app,
    resume: async (resumeOptions) => {
      await initializeFromStartupPreferences();
      return app.resume(resumeOptions);
    },
    runtime: {
      ...app.runtime,
      getSessionShellSelection: () => effectiveShellSelection,
      initializeSessionShellEnvironmentIfNeeded: recordShellInitialization,
    } as never,
    sendInput: async (input, sendOptions) => {
      await initializeFromStartupPreferences();
      return app.sendInput(input, sendOptions);
    },
  };
}
