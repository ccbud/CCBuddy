import Foundation

protocol UpdateRelaunchScheduling: Sendable {
    func scheduleRelaunch(of applicationURL: URL, afterProcess processID: Int32) throws
}

struct UpdateRelaunchCoordinator: UpdateRelaunchScheduling {
    func scheduleRelaunch(of applicationURL: URL, afterProcess processID: Int32) throws {
        let values = try applicationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard applicationURL.isFileURL, applicationURL.pathExtension == "app",
              values.isDirectory == true, values.isSymbolicLink != true,
              processID > 1
        else { throw UpdateServiceError.installation("无法为更新后的应用安排安全重启") }

        // The script is fixed; the PID and path are positional arguments, never shell-expanded
        // source text. It waits for the single-instance lock owner to exit before opening the
        // replacement bundle.
        let script = """
        pid="$1"
        app="$2"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.1; done
        exec /usr/bin/open -n "$app"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", script, "ccbud-update-relauncher", String(processID), applicationURL.path,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() }
        catch { throw UpdateServiceError.installation("无法启动更新重启助手：\(error.localizedDescription)") }
    }
}
