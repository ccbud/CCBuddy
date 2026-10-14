export function shouldOpenWorkflowArtifactInBrowser(params: {
  contentType?: string;
  supportsEmbeddedBrowser: boolean;
  workspaceIdentity?: string;
  remoteSessionId?: string;
}): boolean {
  return (
    params.contentType === "text/html" &&
    params.supportsEmbeddedBrowser &&
    !params.workspaceIdentity?.trim() &&
    !params.remoteSessionId
  );
}
