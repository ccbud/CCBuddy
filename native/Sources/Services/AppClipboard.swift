import AppKit
import Foundation

enum AppClipboard {
    private static let uiTestCaptureFilename = ".ccbud-ui-test-clipboard"

    @discardableResult
    static func write(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        pasteboard.clearContents()
        let didWrite = pasteboard.setString(text, forType: .string)

#if DEBUG
        if environment["CCBUD_UI_TESTING"] == "1",
           let home = environment["CCBUD_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            let captureURL = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(uiTestCaptureFilename, isDirectory: false)
            try? SecureAtomicFile.write(Data(text.utf8), to: captureURL)
        }
#endif

        return didWrite
    }
}
