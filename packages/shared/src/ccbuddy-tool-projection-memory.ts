import type { CCbuddyStreamingToolInputState } from "./streaming-tool-input-preview.js";

export interface CCbuddyToolProjectionMemory {
  completeToolInputById?: Map<string, unknown>;
  streamingToolInputById?: Map<string, CCbuddyStreamingToolInputState>;
  toolNameById?: Map<string, string>;
}

export interface CCbuddyToolProjectionMetadata {
  hasInput: boolean;
  input?: unknown;
  toolName?: string;
}

export function createCCbuddyToolProjectionMemory(): CCbuddyToolProjectionMemory {
  return {
    completeToolInputById: new Map<string, unknown>(),
    streamingToolInputById: new Map<string, CCbuddyStreamingToolInputState>(),
    toolNameById: new Map<string, string>(),
  };
}

export function ensureCCbuddyToolProjectionMemory(
  memory: CCbuddyToolProjectionMemory,
): CCbuddyToolProjectionMemory {
  memory.completeToolInputById ??= new Map<string, unknown>();
  memory.streamingToolInputById ??= new Map<string, CCbuddyStreamingToolInputState>();
  memory.toolNameById ??= new Map<string, string>();
  return memory;
}

export function resolveCCbuddyToolProjectionMetadata(
  payload: Record<string, unknown>,
  toolId: string,
  memory: CCbuddyToolProjectionMemory,
): CCbuddyToolProjectionMetadata {
  const toolName = readNonEmptyString(payload.toolName) ?? memory.toolNameById?.get(toolId);
  if (toolName) {
    memory.toolNameById?.set(toolId, toolName);
  }

  if ("input" in payload) {
    return {
      hasInput: payload.input !== undefined,
      input: payload.input,
      toolName,
    };
  }

  if (memory.completeToolInputById?.has(toolId)) {
    return {
      hasInput: true,
      input: memory.completeToolInputById.get(toolId),
      toolName,
    };
  }

  return {
    hasInput: false,
    toolName,
  };
}

export function finalizeCCbuddyToolProjectionInput(
  toolId: string,
  input: unknown,
  memory: CCbuddyToolProjectionMemory,
): void {
  memory.completeToolInputById ??= new Map<string, unknown>();
  memory.completeToolInputById.set(toolId, input);
  const streamingState = memory.streamingToolInputById?.get(toolId);
  if (streamingState) {
    streamingState.lastPreviewRawInputLength = streamingState.rawInput.length;
    streamingState.rawInput = "";
  }
}

export function forgetCCbuddyToolProjectionMetadata(
  toolId: string,
  memory: CCbuddyToolProjectionMemory,
): void {
  memory.completeToolInputById?.delete(toolId);
  memory.streamingToolInputById?.delete(toolId);
  memory.toolNameById?.delete(toolId);
}

function readNonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
