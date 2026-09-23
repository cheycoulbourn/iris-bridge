import Foundation

/// The latest snapshot each profile pushed over the v3 stream, kept on disk so a terminal agent can read
/// the workspace while no app is connected and after the helper restarts. Falls back to the v2 context an
/// older app pushed with `PUT /context` when no v3 app has ever pushed.
public final class SnapshotStore: @unchecked Sendable {
    public static let maximumBytes = 16 * 1024 * 1024

    public struct Held { public var snapshot: IrisSnapshot; public var receivedAt: Date }

    private struct Stored { var profileID: String; var revision: String; var receivedAt: Date; var raw: JSONValue }

    private let folder: URL
    private let legacy: ContextStore
    private let now: () -> Date
    private let lock = NSLock()
    private var stored: [String: Stored] = [:]
    private var latest: String?

    public init(folder: URL, legacy: ContextStore, now: @escaping () -> Date = Date.init) {
        self.folder = folder; self.legacy = legacy; self.now = now
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)), let file = try? JSONValue.decode(data),
                  let profileID = file["profileId"]?.stringValue, UUID(uuidString: profileID) != nil,
                  let snapshot = file["snapshot"], let revision = file["revision"]?.stringValue,
                  let receivedAt = file["receivedAt"]?.stringValue.flatMap(IrisSnapshot.timestamp) else { continue }
            stored[profileID] = Stored(profileID: profileID, revision: revision, receivedAt: receivedAt, raw: snapshot)
        }
        latest = stored.values.max(by: { $0.receivedAt < $1.receivedAt })?.profileID
    }

    /// `snapshot.push`. Returns why it was refused, or nil when it was kept.
    public func push(profileId: String, revision: String, snapshot: JSONValue) -> String? {
        guard let uuid = UUID(uuidString: profileId) else { return "That profile id is not valid." }
        guard snapshot["schemaVersion"]?.intValue == IrisSnapshot.schemaVersion else {
            return "That snapshot uses a schema this Iris Bridge does not read. Update Iris Bridge."
        }
        let key = uuid.uuidString
        let entry = Stored(profileID: key, revision: revision, receivedAt: now(), raw: snapshot)
        let file: JSONValue = ["profileId": .string(key), "revision": .string(revision),
                               "receivedAt": .string(ISO8601DateFormatter().string(from: entry.receivedAt)), "snapshot": snapshot]
        let data = file.encoded()
        guard data.count <= Self.maximumBytes else { return "That workspace snapshot is too large." }
        do { try BridgePaths.writePrivate(data, to: folder.appendingPathComponent(key + ".json")) }
        catch { return "Iris Bridge could not save that workspace snapshot." }
        lock.lock(); stored[key] = entry; latest = key; lock.unlock()
        return nil
    }

    /// The snapshot for a profile, or for the profile pushed most recently when `profileID` is nil. Only
    /// when no v3 snapshot exists at all does it read an older app's v2 context.
    public func snapshot(profileID: String?) -> Held? {
        lock.lock()
        let key = profileID.flatMap(UUID.init(uuidString:))?.uuidString ?? (profileID == nil ? latest : nil)
        let entry = key.flatMap { stored[$0] }
        let hasAny = !stored.isEmpty
        lock.unlock()
        if let entry {
            return Held(snapshot: IrisSnapshot(json: entry.raw, profileID: entry.profileID, revision: entry.revision), receivedAt: entry.receivedAt)
        }
        guard !hasAny, let context = legacy.current else { return nil }
        let snapshot = IrisSnapshot(legacy: context)
        if let profileID, UUID(uuidString: profileID)?.uuidString != UUID(uuidString: snapshot.profileID)?.uuidString { return nil }
        return Held(snapshot: snapshot, receivedAt: context.updatedAt)
    }
}
