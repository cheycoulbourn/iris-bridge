import Foundation
import Security

// MARK: - Models

public struct SubmittedScene: Codable, Equatable {
    public var script: String
    public var shotNotes: String
    public init(script: String, shotNotes: String) { self.script = script; self.shotNotes = shotNotes }
}

public struct SubmittedPost: Codable, Equatable {
    public var title: String
    public var pillar: String
    public var platform: String
    public var format: String
    public var postingDate: String?        // yyyy-MM-dd
    public var hook: String?
    public var script: String?
    public var scenes: [SubmittedScene]?
    public var caption: String?
    public var cta: String?
    public var notes: String?
    public var seriesName: String?
    public var episode: Int?
    public init(title: String, pillar: String, platform: String, format: String, postingDate: String? = nil,
                hook: String? = nil, script: String? = nil, scenes: [SubmittedScene]? = nil,
                caption: String? = nil, cta: String? = nil, notes: String? = nil,
                seriesName: String? = nil, episode: Int? = nil) {
        self.title = title; self.pillar = pillar; self.platform = platform; self.format = format
        self.postingDate = postingDate; self.hook = hook; self.script = script; self.scenes = scenes
        self.caption = caption; self.cta = cta; self.notes = notes; self.seriesName = seriesName; self.episode = episode
    }
}

public struct SubmittedEpisode: Codable, Equatable {
    public var number: Int
    public var date: String?
    public var post: SubmittedPost
    public init(number: Int, date: String? = nil, post: SubmittedPost) { self.number = number; self.date = date; self.post = post }
}

public struct SubmittedSeries: Codable, Equatable {
    public var name: String
    public var pillar: String
    public var summary: String?
    public var episodes: [SubmittedEpisode]
    public init(name: String, pillar: String, summary: String? = nil, episodes: [SubmittedEpisode]) {
        self.name = name; self.pillar = pillar; self.summary = summary; self.episodes = episodes
    }
}

public enum SubmissionKind: String, Codable { case post, series }
public enum SubmissionStatus: String, Codable { case pending, approved, denied, changesRequested }

public struct Submission: Codable, Equatable, Identifiable {
    public var id: String                  // "sub_" + 12 random alphanumerics
    public var kind: SubmissionKind
    public var post: SubmittedPost?
    public var series: SubmittedSeries?
    public var agent: String               // "claude" | "codex" | free text from the MCP client name
    public var note: String?               // the agent's cover note
    public var status: SubmissionStatus
    public var comment: String?            // creator's comment on deny / changes
    public var createdAt: Date
    public var decidedAt: Date?
    public var revisionOf: String?         // when the agent resubmits after changes
    public init(id: String, kind: SubmissionKind, post: SubmittedPost? = nil, series: SubmittedSeries? = nil,
                agent: String, note: String? = nil, status: SubmissionStatus = .pending, comment: String? = nil,
                createdAt: Date, decidedAt: Date? = nil, revisionOf: String? = nil) {
        self.id = id; self.kind = kind; self.post = post; self.series = series; self.agent = agent; self.note = note
        self.status = status; self.comment = comment; self.createdAt = createdAt; self.decidedAt = decidedAt; self.revisionOf = revisionOf
    }
}

/// Text on its way to a single printed line. Titles and comments are written by an agent or typed by a
/// creator on a phone: they arrive with newlines in them, with tabs, with the odd terminal escape sequence
/// pasted in from somewhere, and at any length. Printed raw into `iris-bridge inbox` or an MCP tool result,
/// a newline breaks one submission into rows that look like several, an escape sequence recolours the rest of
/// the Terminal session, and a three-thousand-character title buries every other line on the screen.
public enum OneLineText {
    /// Runs of whitespace collapse to one space, control characters and escape sequences are dropped, and
    /// `limit` — when given — is the longest the result may be, the ellipsis included.
    public static func clean(_ text: String, limit: Int? = nil) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == escape { index = endOfEscape(scalars, from: index); continue }
            index += 1
            // Leading whitespace is dropped rather than remembered, and trailing whitespace never arrives:
            // a pending space is only ever written in front of something visible.
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { pendingSpace = !out.isEmpty; continue }
            if isControl(scalar) { continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
        }
        return truncate(String(out), to: limit)
    }

    private static let escape: Unicode.Scalar = "\u{1B}"

    /// ASCII controls and DEL, plus the C1 block: none of them draw anything, and several move the cursor.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    /// The index just past an escape sequence beginning at `start`. A CSI run (`ESC [ … m`) ends at its final
    /// byte and an OSC run (`ESC ] … BEL`) at its terminator; anything else is two characters. Dropping the
    /// ESC alone would leave `[31m` on the line, which is worse than either.
    private static func endOfEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        guard index < scalars.count else { return index }
        switch scalars[index] {
        case "[":
            index += 1
            while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
            return min(index + 1, scalars.count)
        case "]":
            index += 1
            while index < scalars.count {
                if scalars[index].value == 0x07 { return index + 1 }
                if scalars[index] == escape, index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
                index += 1
            }
            return index
        default:
            return index + 1
        }
    }

    private static func truncate(_ text: String, to limit: Int?) -> String {
        guard let limit, limit > 0, text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension Submission {
    /// The longest a title may be on a listed line. Long enough for a real working title, short enough that
    /// the id, kind, status and age after it still fit in a Terminal window.
    public static let listTitleLimit = 80

    /// `displayTitle` made fit for one printed line: no newlines, no escape sequences, 80 characters at most.
    public var listTitle: String { OneLineText.clean(displayTitle, limit: Self.listTitleLimit) }

    /// What to call this submission in a list. A post carries its own title, a series its name; a submission
    /// with neither is malformed rather than nameless, and still has to print as a line.
    public var displayTitle: String {
        if let title = post?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let name = series?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return kind == .series ? "Untitled series" : "Untitled post"
    }

    /// How long this has been waiting, in the shortest form that is still true: "3m", "2h", "1d".
    public func ageText(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(createdAt))
        if seconds < 3600 { return "\(Int(seconds) / 60)m" }
        if seconds < 86_400 { return "\(Int(seconds) / 3600)h" }
        return "\(Int(seconds) / 86_400)d"
    }
}

public struct WorkspaceContext: Codable, Equatable {   // pushed by the app
    public var creatorName: String
    public var pillars: [ContextPillar]
    public var platforms: [ContextPlatform]
    public var series: [ContextSeries]
    public var creatorContext: String?
    public var updatedAt: Date
    public init(creatorName: String, pillars: [ContextPillar], platforms: [ContextPlatform],
                series: [ContextSeries], creatorContext: String? = nil, updatedAt: Date) {
        self.creatorName = creatorName; self.pillars = pillars; self.platforms = platforms
        self.series = series; self.creatorContext = creatorContext; self.updatedAt = updatedAt
    }
}

public struct ContextPillar: Codable, Equatable {
    public var name: String
    public var detail: String
    public var isAnchor: Bool
    public var weekdays: [Int]
    public init(name: String, detail: String, isAnchor: Bool, weekdays: [Int]) {
        self.name = name; self.detail = detail; self.isAnchor = isAnchor; self.weekdays = weekdays
    }
}

public struct ContextPlatform: Codable, Equatable {
    public var name: String
    public var formats: [String]
    public var weeklyGoal: Int
    public init(name: String, formats: [String], weeklyGoal: Int) { self.name = name; self.formats = formats; self.weeklyGoal = weeklyGoal }
}

public struct ContextSeries: Codable, Equatable {
    public var name: String
    public var pillar: String
    public var episodes: [ContextEpisode]
    public init(name: String, pillar: String, episodes: [ContextEpisode]) { self.name = name; self.pillar = pillar; self.episodes = episodes }
}

public struct ContextEpisode: Codable, Equatable {
    public var number: Int
    public var date: String?
    public var title: String?
    public var filled: Bool
    public init(number: Int, date: String? = nil, title: String? = nil, filled: Bool) {
        self.number = number; self.date = date; self.title = title; self.filled = filled
    }
}

// MARK: - Limits and validation

public enum SubmissionLimits {
    public static let characters = 24_000
    public static let noteCharacters = 2_000
    public static let scenes = 40
    public static let episodes = 52
    public static let pending = 200
}

public enum SubmissionValidation {
    public static func validate(kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?) throws {
        switch kind {
        case .post:
            guard let post else { throw BridgeError.message("Add a post to submit.") }
            try validate(post: post)
            guard characters(in: post) <= SubmissionLimits.characters else { throw BridgeError.message(tooLong) }
        case .series:
            guard let series else { throw BridgeError.message("Add a series to submit.") }
            guard !trimmed(series.name).isEmpty else { throw BridgeError.message("Give the series a name.") }
            guard !trimmed(series.pillar).isEmpty else { throw BridgeError.message("Choose a pillar.") }
            guard !series.episodes.isEmpty else { throw BridgeError.message("Add at least one episode.") }
            guard series.episodes.count <= SubmissionLimits.episodes else {
                throw BridgeError.message("A series can have up to \(SubmissionLimits.episodes) episodes.")
            }
            for episode in series.episodes { try validate(post: episode.post) }
            var total = series.name.count + (series.summary?.count ?? 0)
            for episode in series.episodes { total += characters(in: episode.post) }
            guard total <= SubmissionLimits.characters else { throw BridgeError.message(tooLong) }
        }
    }

    private static let tooLong = "This submission is too long. Keep it under 24,000 characters."

    private static func validate(post: SubmittedPost) throws {
        guard !trimmed(post.title).isEmpty else { throw BridgeError.message("Give the post a title.") }
        guard !trimmed(post.pillar).isEmpty else { throw BridgeError.message("Choose a pillar.") }
        guard !trimmed(post.platform).isEmpty else { throw BridgeError.message("Choose a platform.") }
        guard (post.scenes?.count ?? 0) <= SubmissionLimits.scenes else {
            throw BridgeError.message("Choose up to \(SubmissionLimits.scenes) scenes.")
        }
    }

    private static func characters(in post: SubmittedPost) -> Int {
        var total = post.title.count + post.pillar.count + post.platform.count + post.format.count
        total += (post.hook?.count ?? 0) + (post.script?.count ?? 0) + (post.caption?.count ?? 0)
        total += (post.cta?.count ?? 0) + (post.notes?.count ?? 0) + (post.seriesName?.count ?? 0)
        for scene in post.scenes ?? [] { total += scene.script.count + scene.shotNotes.count }
        return total
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Inbox errors

/// Why a decision could not be recorded. Typed rather than a sentence so the router picks the status code from
/// the case; the sentences stay here because they are what the app shows.
public enum InboxError: Error, Equatable, LocalizedError {
    case notFound, alreadyDecided
    public var errorDescription: String? {
        switch self {
        case .notFound: return "Not found."
        case .alreadyDecided: return "Already decided."
        }
    }
}

// MARK: - Inbox store

public final class InboxStore: @unchecked Sendable {
    public let file: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var submissions: [Submission]

    public init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file; self.now = now
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        submissions = (try? decoder.decode([Submission].self, from: Data(contentsOf: file))) ?? []
    }

    /// "sub_" + 12 lowercase alphanumerics.
    public static func makeID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Iris Bridge could not generate a submission identifier (\(status)).")
        return "sub_" + String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static let idAlphabet = Set("abcdefghijklmnopqrstuvwxyz0123456789")

    /// True for "sub_" followed by exactly 12 lowercase alphanumerics, the shape `makeID()` produces.
    static func isSubmissionID(_ id: String) -> Bool {
        guard id.count == 16, id.hasPrefix("sub_") else { return false }
        return id.dropFirst(4).allSatisfy { idAlphabet.contains($0) }
    }

    public func submit(kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?,
                       agent: String, note: String?, revisionOf: String?) throws -> Submission {
        try SubmissionValidation.validate(kind: kind, post: post, series: series)
        lock.lock(); defer { lock.unlock() }
        if let revisionOf, !Self.isSubmissionID(revisionOf) {
            throw BridgeError.message("That submission id is not valid.")
        }
        if let revisionOf {
            guard let original = submissions.first(where: { $0.id == revisionOf }) else {
                throw BridgeError.message("That submission was not found.")
            }
            guard original.kind == kind else { throw BridgeError.message("A revision must keep the original type of work.") }
            if let existing = submissions.first(where: { $0.revisionOf == revisionOf }) {
                // A lost response must not turn a retry into a second approval card.
                if existing.post == post && existing.series == series { return existing }
                throw BridgeError.message("A revision already exists. Read its status and revise that submission after the creator requests changes.")
            }
            guard original.status == .changesRequested else {
                throw BridgeError.message("The creator must request changes before this submission can be revised.")
            }
        }
        // A retry of an already-created revision must remain idempotent even when the Inbox is at capacity.
        guard submissions.filter({ $0.status == .pending }).count < SubmissionLimits.pending else {
            throw BridgeError.message("Iris has \(SubmissionLimits.pending) submissions waiting. Ask the creator to clear the Inbox first.")
        }
        let cleanAgent = String(agent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanNote = trimmedNote.isEmpty ? nil : String(trimmedNote.prefix(SubmissionLimits.noteCharacters))
        let submission = Submission(id: Self.makeID(), kind: kind,
                                    post: kind == .post ? post : nil,
                                    series: kind == .series ? series : nil,
                                    agent: cleanAgent.isEmpty ? "agent" : cleanAgent,
                                    note: cleanNote, status: .pending, comment: nil,
                                    createdAt: now(), decidedAt: nil, revisionOf: revisionOf)
        submissions.append(submission)
        do { try save() } catch { submissions.removeLast(); throw error }
        return submission
    }

    /// Pending submissions plus anything created or decided after `since`; `nil` means the last 30 days. Newest first.
    public func all(since: Date?) -> [Submission] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = since ?? now().addingTimeInterval(-30 * 24 * 60 * 60)
        return Self.newestFirst(submissions.enumerated().filter { _, submission in
            if submission.status == .pending { return true }
            if submission.createdAt > cutoff { return true }
            if let decidedAt = submission.decidedAt, decidedAt > cutoff { return true }
            return false
        })
    }

    public var pending: [Submission] {
        lock.lock(); defer { lock.unlock() }
        return Self.newestFirst(submissions.enumerated().filter { $0.element.status == .pending })
    }

    public func decide(id: String, status: SubmissionStatus, comment: String?) throws -> Submission {
        lock.lock(); defer { lock.unlock() }
        guard let index = submissions.firstIndex(where: { $0.id == id }) else { throw InboxError.notFound }
        guard submissions[index].status == .pending else { throw InboxError.alreadyDecided }
        // A save that fails and a mutation that stays would leave this process answering "approved" for
        // something the file on disk still calls pending: the app is told the decision could not be recorded,
        // then sees it as decided until the helper restarts and it silently becomes pending again.
        let before = submissions[index]
        submissions[index].status = status
        submissions[index].comment = comment
        submissions[index].decidedAt = now()
        do {
            try save()
        } catch {
            submissions[index] = before
            throw error
        }
        return submissions[index]
    }

    /// Drops decided submissions older than `olderThan` seconds. Returns how many went.
    @discardableResult
    public func pruneDecided(olderThan: TimeInterval) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-olderThan)
        let before = submissions.count
        submissions.removeAll { submission in
            guard submission.status != .pending else { return false }
            return (submission.decidedAt ?? submission.createdAt) < cutoff
        }
        let removed = before - submissions.count
        if removed > 0 { try save() }
        return removed
    }

    /// Newest first, falling back to insertion order when two submissions share a timestamp.
    private static func newestFirst(_ items: [(offset: Int, element: Submission)]) -> [Submission] {
        items.sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset > $1.offset : $0.element.createdAt > $1.element.createdAt
        }.map(\.element)
    }

    private func save() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try BridgePaths.writePrivate(try encoder.encode(submissions), to: file)
    }
}

// MARK: - Context store

public final class ContextStore: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private var context: WorkspaceContext?

    public init(file: URL) {
        self.file = file
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        context = try? decoder.decode(WorkspaceContext.self, from: Data(contentsOf: file))
    }

    public var current: WorkspaceContext? {
        lock.lock(); defer { lock.unlock() }
        return context
    }

    public func save(_ context: WorkspaceContext) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try BridgePaths.writePrivate(try encoder.encode(context), to: file)
        self.context = context
    }
}
