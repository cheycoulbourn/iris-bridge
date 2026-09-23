import Foundation

/// Each thread's events on disk, so an app that reconnects replays from its cursor what it missed while a
/// turn kept running (spec §6.3). One JSON line per event in `<folder>/<THREAD-UUID>.jsonl`; the newest
/// `keep` events are kept. A line that cannot be read (a torn write, a newer helper's shape) is skipped, never
/// fatal, and `seq` keeps counting up from the highest one that was read.
public final class EventLog: @unchecked Sendable {
    public static let keep = 2_000
    /// Logs held in memory at once; others are read again from disk when next needed.
    static let cachedThreads = 20

    private struct ThreadLog { var events: [(seq: Int, line: Data)]; var nextSeq: Int }

    private let folder: URL
    private let lock = NSLock()
    private var cache: [String: ThreadLog] = [:]
    private var recent: [String] = []

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Stamps the next `seq` for the thread onto `body`, writes it, and returns the message as it is sent.
    /// Returns nil for a thread id that is not a UUID; nothing is written for one.
    @discardableResult
    public func append(threadId: String, _ body: [String: JSONValue]) -> JSONValue? {
        guard let key = Self.key(threadId) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var log = load(key)
        var stamped = body
        stamped["seq"] = .number(Double(log.nextSeq))
        let message = JSONValue.object(stamped)
        let line = message.encoded()
        log.events.append((log.nextSeq, line))
        log.nextSeq += 1
        if log.events.count > Self.keep + Self.keep / 10 {
            log.events.removeFirst(log.events.count - Self.keep)
            rewrite(key, log)
        } else {
            appendLine(key, line)
        }
        store(key, log)
        return message
    }

    /// The kept events after `cursor`, oldest first. A cursor older than the oldest kept event gets
    /// everything kept; the app sees the jump in `seq`.
    public func replay(threadId: String, after cursor: Int) -> [JSONValue] {
        guard let key = Self.key(threadId) else { return [] }
        lock.lock(); defer { lock.unlock() }
        let log = load(key)
        store(key, log)
        return log.events.filter { $0.seq > cursor }.compactMap { try? JSONValue.decode($0.line) }
    }

    private static func key(_ threadId: String) -> String? { UUID(uuidString: threadId)?.uuidString }

    private func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".jsonl") }

    private func load(_ key: String) -> ThreadLog {
        if let cached = cache[key] { return cached }
        let text = (try? String(contentsOf: file(key), encoding: .utf8)) ?? ""
        var events: [(Int, Data)] = []
        for line in text.split(separator: "\n") {
            let data = Data(line.utf8)
            guard let seq = (try? JSONValue.decode(data))?["seq"]?.intValue else { continue }
            events.append((seq, data))
        }
        events.sort { $0.0 < $1.0 }
        return ThreadLog(events: Array(events.suffix(Self.keep)), nextSeq: (events.last?.0 ?? 0) + 1)
    }

    private func store(_ key: String, _ log: ThreadLog) {
        cache[key] = log
        recent.removeAll { $0 == key }
        recent.append(key)
        while recent.count > Self.cachedThreads { cache[recent.removeFirst()] = nil }
    }

    private func appendLine(_ key: String, _ line: Data) {
        let url = file(key)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        // A torn last line (the helper stopped mid-write) must not swallow this one.
        var torn = false
        if end > 0 {
            try? handle.seek(toOffset: end - 1)
            torn = (try? handle.read(upToCount: 1)) != Data([0x0A])
            _ = try? handle.seekToEnd()
        }
        try? handle.write(contentsOf: (torn ? Data([0x0A]) : Data()) + line + Data([0x0A]))
    }

    private func rewrite(_ key: String, _ log: ThreadLog) {
        let joined = log.events.reduce(into: Data()) { $0.append($1.line); $0.append(0x0A) }
        try? BridgePaths.writePrivate(joined, to: file(key))
    }
}
