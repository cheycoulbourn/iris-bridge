import Foundation

/// Which provider session each thread resumes by, kept on disk (`sessions/index.json`) so a thread picks up
/// its conversation after the helper restarts. Read leniently: an entry this helper cannot read is skipped.
public final class SessionIndex: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var entries: [String: [String: String]] = [:]

    public init(file: URL) {
        self.file = file
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONValue.decode($0) }?.objectValue ?? [:]
        for (thread, value) in saved {
            let ids = (value.objectValue ?? [:]).compactMapValues(\.stringValue)
            if !ids.isEmpty { entries[thread] = ids }
        }
    }

    public func sessionId(threadId: String, provider: Provider) -> String? {
        guard let key = UUID(uuidString: threadId)?.uuidString else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries[key]?[provider.rawValue]
    }

    /// Nil forgets it: the thread's next message starts a new provider conversation.
    public func set(_ sessionId: String?, threadId: String, provider: Provider) {
        guard let key = UUID(uuidString: threadId)?.uuidString else { return }
        lock.lock(); defer { lock.unlock() }
        var ids = entries[key] ?? [:]
        ids[provider.rawValue] = sessionId
        entries[key] = ids.isEmpty ? nil : ids
        let saved = JSONValue.object(entries.mapValues { .object($0.mapValues { .string($0) }) })
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? BridgePaths.writePrivate(saved.encoded(), to: file)
    }
}
