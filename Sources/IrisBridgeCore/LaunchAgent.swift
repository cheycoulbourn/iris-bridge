import Foundation

public enum LaunchAgent {
    public static let label = "com.agentcy.iris-bridge"
    /// Files only the helper writes. `uninstall` refuses to delete a folder that holds none of them.
    public static let folderMarkers = ["admin-token", "certificate.pem", "devices.json"]

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    /// launchd cannot create this itself: if the folder is missing, the job fails to spawn.
    public static var logFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Iris Bridge")
    }
    public static var logFileURL: URL { logFolderURL.appendingPathComponent("launchd.log") }

    public static func plist(binary: String) -> String {
        let logs = logFileURL.path
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
        // Both StandardOutPath and StandardErrorPath live here; launchd will not create the folder.
        try? FileManager.default.createDirectory(at: logFolderURL, withIntermediateDirectories: true)
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

    /// Whether `url` is a folder the helper wrote, i.e. safe to delete whole. `uninstall` removes a directory
    /// tree, so it asks this first: a folder with none of our marker files belongs to somebody else.
    public static func looksLikeBridgeFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return folderMarkers.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    @discardableResult static func launchctl(_ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
