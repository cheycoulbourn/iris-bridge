import Foundation

public final class BridgeLog: @unchecked Sendable {
    private let file: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    public init(file: URL, maxBytes: Int = 5_000_000) { self.file = file; self.maxBytes = maxBytes }
    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERROR", message) }
    private func write(_ level: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size >= maxBytes {
            try? FileManager.default.removeItem(atPath: file.path + ".1")
            try? FileManager.default.moveItem(atPath: file.path, toPath: file.path + ".1")
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}
