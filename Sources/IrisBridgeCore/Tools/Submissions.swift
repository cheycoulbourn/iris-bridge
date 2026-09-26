import Foundation

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

public enum SubmissionKind: String, Codable { case post, series, archive }
public enum SubmissionStatus: String, Codable { case pending, approved, denied, changesRequested }

public struct PlannerPost: Codable, Equatable, Identifiable {
    public var id: UUID
    public var revision: String
    public var title: String
    public var platform: String
    public var format: String
    public var archived: Bool
    public var details: [String: JSONValue]
    public init(id: UUID, revision: String, title: String, platform: String, format: String,
                archived: Bool, details: [String: JSONValue]) {
        self.id = id; self.revision = revision; self.title = title; self.platform = platform
        self.format = format; self.archived = archived; self.details = details
    }
}

public struct PlannerSnapshot: Codable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var accountID: UUID
    public var revision: String
    public var capturedAt: Date
    public var posts: [PlannerPost]
    public init(accountID: UUID, revision: String, capturedAt: Date, posts: [PlannerPost], schemaVersion: Int = Self.schemaVersion) {
        self.schemaVersion = schemaVersion; self.accountID = accountID; self.revision = revision
        self.capturedAt = capturedAt; self.posts = posts
    }
}

public struct ArchiveTarget: Codable, Equatable, Hashable {
    public var id: UUID
    public var revision: String
    public init(id: UUID, revision: String) { self.id = id; self.revision = revision }
}

public struct ArchiveProposal: Codable, Equatable {
    public var accountID: UUID
    public var operationID: UUID
    public var posts: [ArchiveTarget]
    public var reason: String
    public init(accountID: UUID, operationID: UUID, posts: [ArchiveTarget], reason: String) {
        self.accountID = accountID; self.operationID = operationID; self.posts = posts; self.reason = reason
    }
}

public struct Submission: Codable, Equatable, Identifiable {
    public var id: String                  // "sub_" + 12 random alphanumerics
    public var kind: SubmissionKind
    public var post: SubmittedPost?
    public var series: SubmittedSeries?
    public var archive: ArchiveProposal?
    public var agent: String               // "claude" | "codex" | free text from the MCP client name
    public var note: String?               // the agent's cover note
    public var status: SubmissionStatus
    public var comment: String?            // creator's comment on deny / changes
    public var createdAt: Date
    public var decidedAt: Date?
    public var revisionOf: String?         // when the agent resubmits after changes
    public init(id: String, kind: SubmissionKind, post: SubmittedPost? = nil, series: SubmittedSeries? = nil,
                archive: ArchiveProposal? = nil,
                agent: String, note: String? = nil, status: SubmissionStatus = .pending, comment: String? = nil,
                createdAt: Date, decidedAt: Date? = nil, revisionOf: String? = nil) {
        self.id = id; self.kind = kind; self.post = post; self.series = series; self.archive = archive; self.agent = agent; self.note = note
        self.status = status; self.comment = comment; self.createdAt = createdAt; self.decidedAt = decidedAt; self.revisionOf = revisionOf
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
        switch kind {
        case .series: return "Untitled series"
        case .archive: return "Archive proposal"
        case .post: return "Untitled post"
        }
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
    /// The planner snapshot is additive so an older Iris app and helper keep exchanging their existing
    /// workspace fields. A snapshot may contain archived posts; the app owns capture and refresh.
    public var planner: PlannerSnapshot?
    public var creatorName: String
    public var pillars: [ContextPillar]
    public var platforms: [ContextPlatform]
    public var series: [ContextSeries]
    public var creatorContext: String?
    public var updatedAt: Date
    public init(creatorName: String, pillars: [ContextPillar], platforms: [ContextPlatform],
                series: [ContextSeries], creatorContext: String? = nil, updatedAt: Date,
                planner: PlannerSnapshot? = nil) {
        self.creatorName = creatorName; self.pillars = pillars; self.platforms = platforms
        self.series = series; self.creatorContext = creatorContext; self.updatedAt = updatedAt; self.planner = planner
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

// MARK: - Limits

public enum SubmissionLimits {
    /// The longest comment a decision keeps.
    public static let noteCharacters = 2_000
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 timestamp."))
        }
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
