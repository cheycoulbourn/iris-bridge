import Foundation

public enum LaunchAgent {
    public static let label = "com.agentcy.iris-bridge"
    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    public static func plist(binary: String) -> String {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Iris Bridge/launchd.log").path
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(esc(binary))</string><string>serve</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardOutPath</key><string>\(esc(logs))</string>
        <key>StandardErrorPath</key><string>\(esc(logs))</string>
        </dict></plist>
        """
    }
    public static func install(binary: String) throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plist(binary: binary).utf8).write(to: plistURL, options: .atomic)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result == 0 else { throw BridgeError.message("launchctl could not start Iris Bridge (\(result)).") }
    }
    public static func uninstall() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }
    @discardableResult static func launchctl(_ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
