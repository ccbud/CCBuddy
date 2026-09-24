const CCBUDDY_PROCESS_PREFIX = "ccbuddy";
const MAX_PROCESS_NAME_SEGMENT_LENGTH = 24;

function sanitizeProcessNameSegment(value: string | null | undefined): string | null {
  if (!value) {
    return null;
  }

  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!normalized) {
    return null;
  }

  return normalized.slice(0, MAX_PROCESS_NAME_SEGMENT_LENGTH);
}

function joinCCbuddyProcessName(...segments: Array<string | null | undefined>): string {
  const sanitizedSegments = segments
    .map((segment) => sanitizeProcessNameSegment(segment))
    .filter((segment): segment is string => Boolean(segment));
  return [CCBUDDY_PROCESS_PREFIX, ...sanitizedSegments].join("-");
}

function pickWorkspaceTag(workspacePath: string | null | undefined): string | undefined {
  const trimmedPath = workspacePath?.trim();
  if (!trimmedPath) {
    return undefined;
  }

  const parts = trimmedPath.split(/[\\/]+/).filter(Boolean);
  return parts.at(-1) ?? trimmedPath;
}

export function formatCCbuddyMainProcessName(): string {
  return joinCCbuddyProcessName("main");
}

export function formatCCbuddyGpuProcessName(): string {
  return joinCCbuddyProcessName("gpu");
}

export function formatCCbuddyHostProcessName(label?: string): string {
  return joinCCbuddyProcessName("host", label);
}

export function formatCCbuddyRendererProcessName(windowTitle?: string): string {
  const normalizedTitle = windowTitle?.trim();
  if (!normalizedTitle || normalizedTitle === "CCbuddy") {
    return joinCCbuddyProcessName("renderer", "main");
  }

  if (normalizedTitle === "Resource Manager") {
    return joinCCbuddyProcessName("renderer", "resource-manager");
  }

  const remoteWindowPrefix = "CCbuddy - ";
  if (normalizedTitle.startsWith(remoteWindowPrefix)) {
    return joinCCbuddyProcessName(
      "renderer",
      "remote",
      normalizedTitle.slice(remoteWindowPrefix.length),
    );
  }

  return joinCCbuddyProcessName("renderer", normalizedTitle);
}

export function formatCCbuddyAgentProcessName(provider: string, workspacePath?: string): string {
  return joinCCbuddyProcessName("agent", provider, pickWorkspaceTag(workspacePath));
}

export function formatCCbuddyUtilityProcessName(name?: string, type = "utility"): string {
  return joinCCbuddyProcessName(type, name);
}
