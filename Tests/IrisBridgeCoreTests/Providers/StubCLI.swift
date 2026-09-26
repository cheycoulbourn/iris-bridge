import Foundation

/// A provider CLI written as a shell script, for tests that run real processes through `ForegroundProcessRunner`.
enum StubCLI {
    /// Writes `#!/bin/sh` and `body` to an executable file of its own and returns its path.
    static func write(_ body: String, name: String = "claude") throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iris-stub-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}

/// Something a CLI starts and leaves running with the CLI's stdout and stderr still open, in a session of its own so
/// that no signal to the CLI's process group reaches it: the way a CLI that starts a background helper can leave
/// them. `command` is the shell line that starts it and records its pid; `stop` ends it.
final class LeftBehind {
    private let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("iris-left-behind-\(UUID().uuidString).pid")
    var command: String { "/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); sleep 30' & echo $! > '\(pidFile.path)'" }
    private var pid: pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    var isRunning: Bool { pid.map { kill($0, 0) == 0 } ?? false }
    func stop() {
        if let pid { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile)
    }
}
