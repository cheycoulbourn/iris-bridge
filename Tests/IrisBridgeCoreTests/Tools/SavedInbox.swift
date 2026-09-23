import Foundation
@testable import IrisBridgeCore

/// Nothing in 0.3.0 creates v2 submissions any more; the v2 Inbox only serves what helper 0.2.x saved. So
/// tests start from an `inbox.json` written the way 0.2.x wrote it.
enum SavedInbox {
    static func post(_ id: String = "sub_" + String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }),
                     title: String = "Three shots", createdAt: Date = Date()) -> Submission {
        Submission(id: id, kind: .post, post: SubmittedPost(title: title, pillar: "Craft", platform: "Instagram", format: "Reel"),
                   agent: "claude", note: "Ready for you.", createdAt: createdAt)
    }

    static func write(_ submissions: [Submission], to file: URL) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! BridgePaths.writePrivate(try! encoder.encode(submissions), to: file)
    }

    static func store(_ submissions: [Submission], file: URL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathComponent("inbox.json"),
                      now: @escaping () -> Date = Date.init) -> InboxStore {
        write(submissions, to: file)
        return InboxStore(file: file, now: now)
    }
}
