import Foundation

/// The compact planner snapshot the Iris read tools answer from (spec §6.2 `snapshot.push`, schema 2; the
/// plan's contract §5 lists every key). Read field by field from JSON: a missing or mistyped field takes an
/// empty default and an unknown one is ignored, so a snapshot from a newer or older app always reads.
public struct IrisSnapshot: Equatable {
    public static let schemaVersion = 2

    public enum Source: String { case stream, legacy }

    public struct Profile: Equatable { public var id, name, handle: String; public var active: Bool }
    public struct Pillar: Equatable { public var id, name, detail: String; public var isAnchor: Bool; public var weekdays: [Int] }
    public struct Platform: Equatable { public var name: String; public var formats: [String]; public var weeklyGoal: Int }
    public struct Scene: Equatable { public var id, script, shotNotes: String }
    public struct Post: Equatable {
        public var id, revision, title, stage, pillar, platform, format: String
        /// `yyyy-MM-dd` and `HH:mm`, on the creator's clock.
        public var date: String
        public var time: String?
        public var seriesID: String?
        public var episode: Int?
        public var archived: Bool
        public var hook, script, caption, cta, notes: String
        public var scenes: [Scene]
        public var liveURL: String?
    }
    public struct Subtask: Equatable { public var title: String; public var done: Bool }
    public struct TaskItem: Equatable {
        public var id, revision, title, notes: String
        public var dueDate: String?
        public var dueTime: String?
        public var done: Bool
        public var postID: String?
        public var subtasks: [Subtask]
        public var archived: Bool
    }
    public struct Idea: Equatable {
        public var id, revision, title, note: String
        public var pillar: String?
        public var archived: Bool
    }
    public struct Episode: Equatable { public var number: Int; public var date: String; public var postID: String? }
    public struct Series: Equatable {
        public var id, revision, name, pillar, summary: String
        public var archived: Bool
        public var episodes: [Episode]
    }
    public struct FocusTheme: Equatable { public var title: String; public var weekdays: [Int] }
    public struct ReviewItem: Equatable {
        public var id, title, reason, status, source: String
        public var comment: String?
        public var createdAt: String
    }

    public var profileID: String
    public var revision: String
    public var source: Source
    public var capturedAt: Date?
    public var timeZone: TimeZone
    public var creatorName: String
    public var creatorContext: String?
    public var profiles: [Profile]
    public var pillars: [Pillar]
    public var platforms: [Platform]
    public var posts: [Post]
    public var tasks: [TaskItem]
    public var ideas: [Idea]
    public var series: [Series]
    public var focusThemes: [FocusTheme]
    public var reviewItems: [ReviewItem]

    /// A snapshot pushed over the v3 stream.
    public init(json: JSONValue, profileID: String, revision: String) {
        func text(_ value: JSONValue?, _ key: String) -> String { value?[key]?.stringValue ?? "" }
        func optional(_ value: JSONValue?, _ key: String) -> String? {
            guard let found = value?[key]?.stringValue, !found.isEmpty else { return nil }
            return found
        }
        func flag(_ value: JSONValue?, _ key: String) -> Bool { value?[key]?.boolValue ?? false }
        func list(_ key: String) -> [JSONValue] { json[key]?.arrayValue ?? [] }
        func days(_ value: JSONValue?) -> [Int] { (value?["weekdays"]?.arrayValue ?? []).compactMap(\.intValue).filter { (1...7).contains($0) } }

        self.profileID = profileID
        self.revision = revision
        source = .stream
        capturedAt = json["capturedAt"]?.stringValue.flatMap(IrisSnapshot.timestamp)
        timeZone = json["timeZone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? .current
        creatorName = text(json, "creatorName")
        creatorContext = optional(json, "creatorContext")
        profiles = list("profiles").map { Profile(id: text($0, "id"), name: text($0, "name"), handle: text($0, "handle"), active: flag($0, "active")) }
        pillars = list("pillars").map { Pillar(id: text($0, "id"), name: text($0, "name"), detail: text($0, "detail"), isAnchor: flag($0, "isAnchor"), weekdays: days($0)) }
        platforms = list("platforms").map {
            Platform(name: text($0, "name"), formats: ($0["formats"]?.arrayValue ?? []).compactMap(\.stringValue), weeklyGoal: $0["weeklyGoal"]?.intValue ?? 0)
        }
        posts = list("posts").map { post in
            Post(id: text(post, "id"), revision: text(post, "revision"), title: text(post, "title"), stage: text(post, "stage"),
                 pillar: text(post, "pillar"), platform: text(post, "platform"), format: text(post, "format"),
                 date: text(post, "date"), time: optional(post, "time"), seriesID: optional(post, "seriesID"),
                 episode: post["episode"]?.intValue, archived: flag(post, "archived"),
                 hook: text(post, "hook"), script: text(post, "script"), caption: text(post, "caption"), cta: text(post, "cta"),
                 notes: text(post, "notes"),
                 scenes: (post["scenes"]?.arrayValue ?? []).map { Scene(id: text($0, "id"), script: text($0, "script"), shotNotes: text($0, "shotNotes")) },
                 liveURL: optional(post, "liveURL"))
        }
        tasks = list("tasks").map { task in
            TaskItem(id: text(task, "id"), revision: text(task, "revision"), title: text(task, "title"), notes: text(task, "notes"),
                     dueDate: optional(task, "dueDate"), dueTime: optional(task, "dueTime"), done: flag(task, "done"),
                     postID: optional(task, "postID"),
                     subtasks: (task["subtasks"]?.arrayValue ?? []).map { Subtask(title: text($0, "title"), done: flag($0, "done")) },
                     archived: flag(task, "archived"))
        }
        ideas = list("ideas").map {
            Idea(id: text($0, "id"), revision: text($0, "revision"), title: text($0, "title"), note: text($0, "note"),
                 pillar: optional($0, "pillar"), archived: flag($0, "archived"))
        }
        series = list("series").map { item in
            Series(id: text(item, "id"), revision: text(item, "revision"), name: text(item, "name"), pillar: text(item, "pillar"),
                   summary: text(item, "summary"), archived: flag(item, "archived"),
                   episodes: (item["episodes"]?.arrayValue ?? []).compactMap { episode in
                       episode["number"]?.intValue.map { Episode(number: $0, date: text(episode, "date"), postID: optional(episode, "postID")) }
                   })
        }
        focusThemes = list("focusThemes").map { FocusTheme(title: text($0, "title"), weekdays: days($0)) }
        reviewItems = list("reviewItems").map {
            ReviewItem(id: text($0, "id"), title: text($0, "title"), reason: text($0, "reason"), status: text($0, "status"),
                       source: text($0, "source"), comment: optional($0, "comment"), createdAt: text($0, "createdAt"))
        }
    }

    /// What an Iris app older than the v3 chat pushed with `PUT /context`: the workspace outline and, when it
    /// sent one, the active profile's posts (planner schema 1). Tasks, ideas, focus and review items are not
    /// in it. Deleted with the v2 endpoints in phase 6.
    public init(legacy context: WorkspaceContext, timeZone: TimeZone = .current) {
        profileID = context.planner?.accountID.uuidString ?? ""
        revision = context.planner?.revision ?? ""
        source = .legacy
        capturedAt = context.planner?.capturedAt ?? context.updatedAt
        self.timeZone = timeZone
        creatorName = context.creatorName
        creatorContext = context.creatorContext
        profiles = []
        pillars = context.pillars.map { Pillar(id: "", name: $0.name, detail: $0.detail, isAnchor: $0.isAnchor, weekdays: $0.weekdays) }
        platforms = context.platforms.map { Platform(name: $0.name, formats: $0.formats, weeklyGoal: $0.weeklyGoal) }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = timeZone; day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.timeZone = timeZone; clock.dateFormat = "HH:mm"
        posts = (context.planner?.posts ?? []).map { post in
            let details = post.details
            let when = details["date"]?.numberValue.map(Date.init(timeIntervalSinceReferenceDate:))
            let status = details["status"]?.stringValue
            let workflow = details["workflow"]?["stage"]?.stringValue ?? "drafted"
            let stage = status == "Posted" ? "published" : status == "Scheduled" ? "scheduled"
                : (workflow == "scheduled" || workflow == "published" ? "drafted" : workflow)
            return Post(id: post.id.uuidString, revision: post.revision, title: post.title, stage: stage,
                        pillar: details["pillar"]?.stringValue ?? "", platform: post.platform, format: post.format,
                        date: when.map(day.string(from:)) ?? "",
                        time: details["includesTime"]?.boolValue == true ? when.map(clock.string(from:)) : nil,
                        seriesID: details["seriesSlotID"]?.stringValue, episode: details["episode"]?.stringValue.flatMap { Int($0) },
                        archived: post.archived, hook: details["hook"]?.stringValue ?? "", script: details["script"]?.stringValue ?? "",
                        caption: details["caption"]?.stringValue ?? "", cta: details["ending"]?.stringValue ?? "",
                        notes: details["notes"]?.stringValue ?? "",
                        scenes: (details["scenes"]?.arrayValue ?? []).map {
                            Scene(id: $0["id"]?.stringValue ?? "", script: $0["text"]?.stringValue ?? "", shotNotes: $0["shotNotes"]?.stringValue ?? "")
                        },
                        liveURL: details["liveURL"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
        tasks = []; ideas = []
        series = context.series.map { item in
            Series(id: "", revision: "", name: item.name, pillar: item.pillar, summary: "", archived: false,
                   episodes: item.episodes.map { Episode(number: $0.number, date: $0.date ?? "", postID: nil) })
        }
        focusThemes = []; reviewItems = []
    }

    static func timestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
