/// Keeps the header's statistics aligned with the transcript already on screen.
///
/// A catalog refresh can publish bounded-prefix statistics while full indexing is still running.
/// Those quick rows remain authoritative for editable metadata, but cannot replace the exact
/// counts of a loaded transcript. Keep every non-statistical field from the selected catalog row.
enum ConversationHeaderStatistics {
    static func metadata(
        selectedMetadata: HistorySessionMetadata,
        loadedParent: HistorySession?,
        activeTranscript: HistorySession?
    ) -> HistorySessionMetadata {
        guard let loadedParent,
              ConversationFilter.fileKey(loadedParent.metadata.file)
                == ConversationFilter.fileKey(selectedMetadata.file) else {
            return selectedMetadata
        }

        let transcriptMetadata = (activeTranscript ?? loadedParent).metadata
        var result = selectedMetadata
        result.messageCount = transcriptMetadata.messageCount
        result.totals = transcriptMetadata.totals
        return result
    }
}
