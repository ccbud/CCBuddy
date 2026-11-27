export function formatResumeResult(sessionId, result) {
    return [
        `Resumed session ${sessionId}.`,
        `Directory: ${result.directory}`,
        `Messages: ${result.appliedMessageCount}/${result.messageCount}; parts: ${result.partCount}; interrupted tools: ${result.interruptedToolCount}`,
    ].join("\n");
}
export function formatNewSessionResult(sessionId) {
    return `Started new session ${sessionId}.`;
}
