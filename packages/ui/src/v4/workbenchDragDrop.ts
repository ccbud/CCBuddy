export const WORKBENCH_SESSION_DRAG_MIME = "application/x-ccbuddy-session";

export interface WorkbenchSessionDragPayload {
  readonly kind: "ccbuddy/session";
  readonly workspacePath: string;
  readonly workspaceIdentity?: string;
  readonly remoteSessionId?: string;
  readonly sessionId: string;
}

let activeWorkbenchSessionDragPayload: WorkbenchSessionDragPayload | null = null;

interface DataTransferLike {
  readonly types?: Iterable<string> | ArrayLike<string>;
  getData(type: string): string;
}

export function serializeWorkbenchSessionDragPayload(payload: WorkbenchSessionDragPayload): string {
  return JSON.stringify(payload);
}

export function setActiveWorkbenchSessionDragPayload(payload: WorkbenchSessionDragPayload): void {
  activeWorkbenchSessionDragPayload = payload;
}

export function clearActiveWorkbenchSessionDragPayload(): void {
  activeWorkbenchSessionDragPayload = null;
}

function dataTransferHasType(dataTransfer: DataTransferLike): boolean {
  return Array.from(dataTransfer.types ?? []).includes(WORKBENCH_SESSION_DRAG_MIME);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseWorkbenchSessionDragPayload(
  dataTransfer: DataTransferLike,
): WorkbenchSessionDragPayload | null {
  if (!dataTransferHasType(dataTransfer)) {
    return null;
  }
  try {
    const raw = dataTransfer.getData(WORKBENCH_SESSION_DRAG_MIME);
    if (!raw) {
      return activeWorkbenchSessionDragPayload;
    }
    const parsed = JSON.parse(raw);
    if (
      !isRecord(parsed) ||
      parsed.kind !== "ccbuddy/session" ||
      typeof parsed.workspacePath !== "string" ||
      typeof parsed.sessionId !== "string"
    ) {
      return null;
    }
    return {
      kind: "ccbuddy/session",
      workspacePath: parsed.workspacePath,
      workspaceIdentity:
        typeof parsed.workspaceIdentity === "string" ? parsed.workspaceIdentity : undefined,
      remoteSessionId:
        typeof parsed.remoteSessionId === "string" ? parsed.remoteSessionId : undefined,
      sessionId: parsed.sessionId,
    };
  } catch {
    return null;
  }
}
