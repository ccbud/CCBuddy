import Foundation

enum HistoryTestSupport {
    static func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbuddy-history-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func write(
        _ lines: [String],
        to file: URL,
        modifiedAt: Date? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        }
        return file
    }

    static func claudeLine(
        type: String,
        role: String,
        contentJSON: String,
        sessionID: String,
        cwd: String,
        timestamp: String,
        extra: String = ""
    ) -> String {
        #"{"type":"\#(type)","message":{"role":"\#(role)","content":\#(contentJSON)},"sessionId":"\#(sessionID)","cwd":"\#(cwd)","timestamp":"\#(timestamp)"\#(extra)}"#
    }

    static func codexLine(timestamp: String, type: String, payload: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"\#(type)","payload":\#(payload)}"#
    }
}
