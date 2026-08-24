import Foundation

/// Oh My Pi stores the same message/tool JSONL as Pi under a different producer root.
enum OMPHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        PiHistoryParser.parse(context, source: .omp)
    }
}
