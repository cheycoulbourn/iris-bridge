import Foundation

/// The Iris read tools (spec §5.1), answered from the latest snapshot the app pushed (spec §6.5). Every
/// answer says how old that snapshot is. Nothing here changes anything.
public struct IrisReadTools {
    let snapshots: SnapshotStore
    let hasPairedDevices: () -> Bool
    let now: () -> Date

    public init(snapshots: SnapshotStore, hasPairedDevices: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        self.snapshots = snapshots; self.hasPairedDevices = hasPairedDevices; self.now = now
    }

    static let noSnapshot = "Iris has not shared its workspace with this Mac yet. Open Iris on a paired iPhone or Mac, then try again."
    static let noProfile = "Iris has not shared that profile's workspace with this Mac. Open that profile in Iris, then try again."

    /// The answer to a read tool, or nil when `name` is not one.
    public func call(_ name: String, _ arguments: [String: JSONValue]) -> ToolResult? {
        guard let tool = IrisToolCatalog.tool(named: name), tool.kind == .read else { return nil }
        let profile = arguments["profileID"]?.stringValue
        guard let held = snapshots.snapshot(profileID: profile) else {
            if profile != nil, snapshots.snapshot(profileID: nil) != nil { return .failure(Self.noProfile) }
            return .failure(hasPairedDevices() ? Self.noSnapshot : Router.notPairedSentence)
        }
        do {
            var body = try answer(name, arguments, held.snapshot)
            body["asOf"] = asOf(held)
            return .json(.object(body))
        } catch {
            return .failure((error as? BridgeError)?.errorDescription ?? "Iris Bridge could not read that.")
        }
    }

    private func asOf(_ held: SnapshotStore.Held) -> JSONValue {
        let minutes = max(0, Int(now().timeIntervalSince(held.receivedAt) / 60))
        var body: [String: JSONValue] = ["revision": .string(held.snapshot.revision), "minutesOld": .number(Double(minutes)),
                                         "receivedAt": .string(ISO8601DateFormatter().string(from: held.receivedAt))]
        if held.snapshot.source == .legacy {
            body["note"] = "From an older Iris app: tasks, ideas, focus themes and Inbox items are not included. Update Iris to see them."
        }
        return .object(body)
    }

    // MARK: - Answers

    private func answer(_ name: String, _ arguments: [String: JSONValue], _ snapshot: IrisSnapshot) throws -> [String: JSONValue] {
        switch name {
        case "iris_workspace_summary": return summary(snapshot)
        case "iris_list_posts": return try listPosts(arguments, snapshot)
        case "iris_get_post":
            let id = try Self.required(arguments, "postID")
            guard let post = snapshot.posts.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw BridgeError.message("That post is not in the workspace Iris shared.")
            }
            return ["post": Self.full(post)]
        case "iris_list_tasks": return try listTasks(arguments, snapshot)
        case "iris_list_ideas":
            let pillar = arguments["pillar"]?.stringValue
            let text = Self.folded(arguments["text"]?.stringValue)
            let archived = arguments["includeArchived"]?.boolValue ?? false
            let ideas = snapshot.ideas.filter { idea in
                (archived || !idea.archived) && (pillar == nil || idea.pillar == pillar)
                    && (text == nil || Self.folded(idea.title + "\n" + idea.note)!.contains(text!))
            }
            return ["ideas": .array(ideas.map(Self.idea))]
        case "iris_list_series":
            let archived = arguments["includeArchived"]?.boolValue ?? false
            return ["series": .array(snapshot.series.filter { archived || !$0.archived }.map { Self.series($0, posts: snapshot.posts) })]
        case "iris_list_pillars":
            return ["pillars": .array(snapshot.pillars.map(Self.pillar))]
        case "iris_get_schedule": return try schedule(arguments, snapshot)
        case "iris_search": return try search(arguments, snapshot)
        case "iris_find_duplicate_posts": return duplicates(snapshot)
        case "iris_list_review_items":
            let all = arguments["status"]?.stringValue == "all"
            return ["items": .array(snapshot.reviewItems.filter { all || $0.status == "pending" || $0.status == "changesRequested" }.map(Self.reviewItem))]
        default:
            throw BridgeError.message("iris-bridge has no read tool called \(name).")
        }
    }

    private func summary(_ snapshot: IrisSnapshot) -> [String: JSONValue] {
        let today = Self.day(now(), in: snapshot.timeZone)
        let active = snapshot.posts.filter { !$0.archived }
        let byStage = Dictionary(grouping: active, by: \.stage).mapValues { JSONValue.number(Double($0.count)) }
        var body: [String: JSONValue] = [
            "creator": .string(snapshot.creatorName),
            "profileID": .string(snapshot.profileID),
            "profiles": .array(snapshot.profiles.map { ["id": .string($0.id), "name": .string($0.name), "handle": .string($0.handle), "open": .bool($0.active)] }),
            "today": .string(today), "timeZone": .string(snapshot.timeZone.identifier),
            "pillars": .array(snapshot.pillars.map(Self.pillar)),
            "platforms": .array(snapshot.platforms.map { ["name": .string($0.name), "formats": .array($0.formats.map { .string($0) }), "weeklyGoal": .number(Double($0.weeklyGoal))] }),
            "counts": ["postsByStage": .object(byStage),
                       "openTasks": .number(Double(snapshot.tasks.filter { !$0.done && !$0.archived }.count)),
                       "ideas": .number(Double(snapshot.ideas.filter { !$0.archived }.count)),
                       "series": .number(Double(snapshot.series.filter { !$0.archived }.count)),
                       "waitingInInbox": .number(Double(snapshot.reviewItems.filter { $0.status == "pending" }.count))]
        ]
        if let context = snapshot.creatorContext { body["creatorNotes"] = .string(context) }
        return body
    }

    private func listPosts(_ arguments: [String: JSONValue], _ snapshot: IrisSnapshot) throws -> [String: JSONValue] {
        let from = try Self.optionalDay(arguments, "from"), to = try Self.optionalDay(arguments, "to")
        let text = Self.folded(arguments["text"]?.stringValue)
        let archived = arguments["includeArchived"]?.boolValue ?? false
        let offset = try Self.whole(arguments, "offset", default: 0, range: 0...Int.max)
        let limit = try Self.whole(arguments, "limit", default: 50, range: 1...100)
        let matching = snapshot.posts.filter { post in
            (archived || !post.archived)
                && (from == nil || (!post.date.isEmpty && post.date >= from!)) && (to == nil || (!post.date.isEmpty && post.date <= to!))
                && Self.matches(arguments["stage"], post.stage) && Self.matches(arguments["pillar"], post.pillar)
                && Self.matches(arguments["platform"], post.platform) && Self.matches(arguments["seriesID"], post.seriesID ?? "")
                && (text == nil || Self.folded([post.title, post.hook, post.script, post.caption, post.notes].joined(separator: "\n"))!.contains(text!))
        }.sorted { ($0.date, $0.time ?? "", $0.id) > ($1.date, $1.time ?? "", $1.id) }
        guard offset <= matching.count else { throw BridgeError.message("That offset is past the end of the matching posts.") }
        let end = min(matching.count, offset + limit)
        return ["posts": .array(matching[offset..<end].map(Self.brief)), "total": .number(Double(matching.count)),
                "nextOffset": end < matching.count ? .number(Double(end)) : .null]
    }

    private func listTasks(_ arguments: [String: JSONValue], _ snapshot: IrisSnapshot) throws -> [String: JSONValue] {
        let status = arguments["status"]?.stringValue ?? "open"
        let from = try Self.optionalDay(arguments, "from"), to = try Self.optionalDay(arguments, "to")
        let text = Self.folded(arguments["text"]?.stringValue)
        let tasks = snapshot.tasks.filter { task in
            !task.archived && (status == "all" || (status == "done") == task.done)
                && (from == nil || (task.dueDate ?? "") >= from!) && (to == nil || (task.dueDate.map { $0 <= to! } ?? false))
                && Self.matches(arguments["postID"], task.postID ?? "")
                && (text == nil || Self.folded(task.title + "\n" + task.notes)!.contains(text!))
        }
        return ["tasks": .array(tasks.map(Self.task))]
    }

    private func schedule(_ arguments: [String: JSONValue], _ snapshot: IrisSnapshot) throws -> [String: JSONValue] {
        guard let from = try Self.optionalDay(arguments, "from"), let to = try Self.optionalDay(arguments, "to"),
              let start = Self.parseDay(from), let end = Self.parseDay(to), start <= end else {
            throw BridgeError.message("Give from and to as yyyy-MM-dd, with from on or before to.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        guard count <= 62 else { throw BridgeError.message("Ask for 62 days or fewer at a time.") }
        let days: [JSONValue] = (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = Self.day(date, in: calendar.timeZone)
            let weekday = calendar.component(.weekday, from: date)
            return ["date": .string(key),
                    "posts": .array(snapshot.posts.filter { !$0.archived && $0.date == key }.map(Self.brief)),
                    "tasksDue": .array(snapshot.tasks.filter { !$0.archived && $0.dueDate == key }.map(Self.task)),
                    "focus": .array(snapshot.focusThemes.filter { $0.weekdays.contains(weekday) }.map { .string($0.title) })]
        }
        return ["days": .array(days)]
    }

    private func search(_ arguments: [String: JSONValue], _ snapshot: IrisSnapshot) throws -> [String: JSONValue] {
        guard let text = Self.folded(arguments["text"]?.stringValue), !text.isEmpty else { throw BridgeError.message("Give the words to find.") }
        let kinds = Set((arguments["kinds"]?.arrayValue ?? []).compactMap(\.stringValue))
        func wanted(_ kind: String) -> Bool { kinds.isEmpty || kinds.contains(kind) }
        func hit(_ parts: [String]) -> Bool { Self.folded(parts.joined(separator: "\n"))!.contains(text) }
        var body: [String: JSONValue] = [:]
        if wanted("post") { body["posts"] = .array(snapshot.posts.filter { !$0.archived && hit([$0.title, $0.hook, $0.script, $0.caption, $0.notes]) }.prefix(50).map(Self.brief)) }
        if wanted("task") { body["tasks"] = .array(snapshot.tasks.filter { !$0.archived && hit([$0.title, $0.notes]) }.prefix(50).map(Self.task)) }
        if wanted("idea") { body["ideas"] = .array(snapshot.ideas.filter { !$0.archived && hit([$0.title, $0.note]) }.prefix(50).map(Self.idea)) }
        if wanted("series") { body["series"] = .array(snapshot.series.filter { !$0.archived && hit([$0.name, $0.summary]) }.prefix(50).map { Self.series($0, posts: snapshot.posts) }) }
        return body
    }

    private func duplicates(_ snapshot: IrisSnapshot) -> [String: JSONValue] {
        func key(_ post: IrisSnapshot.Post) -> String? {
            let parts = [post.title, post.platform, post.format].map { Self.folded($0)!.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            return parts.allSatisfy { !$0.isEmpty } ? parts.joined(separator: "\u{1F}") : nil
        }
        let groups = Dictionary(grouping: snapshot.posts.filter { !$0.archived && key($0) != nil }, by: { key($0)! })
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { JSONValue.object(["title": .string($0.value[0].title), "posts": .array($0.value.sorted { $0.id < $1.id }.map(Self.brief))]) }
        return ["candidates": .array(groups)]
    }

    // MARK: - Shapes the model reads

    static func brief(_ post: IrisSnapshot.Post) -> JSONValue {
        var body: [String: JSONValue] = ["id": .string(post.id), "revision": .string(post.revision), "title": .string(post.title),
                                         "stage": .string(post.stage), "date": .string(post.date), "pillar": .string(post.pillar),
                                         "platform": .string(post.platform), "format": .string(post.format)]
        if let time = post.time { body["time"] = .string(time) }
        if let seriesID = post.seriesID { body["seriesID"] = .string(seriesID) }
        if let episode = post.episode { body["episode"] = .number(Double(episode)) }
        if post.archived { body["archived"] = true }
        return .object(body)
    }

    static func full(_ post: IrisSnapshot.Post) -> JSONValue {
        guard case .object(var body) = brief(post) else { return brief(post) }
        body["hook"] = .string(post.hook); body["script"] = .string(post.script); body["caption"] = .string(post.caption)
        body["cta"] = .string(post.cta); body["notes"] = .string(post.notes)
        body["scenes"] = .array(post.scenes.map { ["id": .string($0.id), "script": .string($0.script), "shotNotes": .string($0.shotNotes)] })
        if let url = post.liveURL { body["liveURL"] = .string(url) }
        return .object(body)
    }

    static func task(_ task: IrisSnapshot.TaskItem) -> JSONValue {
        var body: [String: JSONValue] = ["id": .string(task.id), "revision": .string(task.revision), "title": .string(task.title),
                                         "done": .bool(task.done),
                                         "subtasks": .array(task.subtasks.map { ["title": .string($0.title), "done": .bool($0.done)] })]
        if !task.notes.isEmpty { body["notes"] = .string(task.notes) }
        if let due = task.dueDate { body["dueDate"] = .string(due) }
        if let time = task.dueTime { body["dueTime"] = .string(time) }
        if let post = task.postID { body["postID"] = .string(post) }
        return .object(body)
    }

    static func idea(_ idea: IrisSnapshot.Idea) -> JSONValue {
        var body: [String: JSONValue] = ["id": .string(idea.id), "revision": .string(idea.revision), "title": .string(idea.title), "note": .string(idea.note)]
        if let pillar = idea.pillar { body["pillar"] = .string(pillar) }
        return .object(body)
    }

    static func series(_ series: IrisSnapshot.Series, posts: [IrisSnapshot.Post]) -> JSONValue {
        ["id": .string(series.id), "revision": .string(series.revision), "name": .string(series.name), "pillar": .string(series.pillar),
         "summary": .string(series.summary),
         "episodes": .array(series.episodes.map { episode in
             var body: [String: JSONValue] = ["number": .number(Double(episode.number)), "date": .string(episode.date)]
             if let id = episode.postID {
                 body["postID"] = .string(id)
                 body["title"] = posts.first { $0.id == id }.map { .string($0.title) } ?? .null
             }
             return .object(body)
         })]
    }

    static func pillar(_ pillar: IrisSnapshot.Pillar) -> JSONValue {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return ["name": .string(pillar.name), "detail": .string(pillar.detail), "anchor": .bool(pillar.isAnchor),
                "usualDays": .array(pillar.weekdays.map { .string(names[$0]) })]
    }

    static func reviewItem(_ item: IrisSnapshot.ReviewItem) -> JSONValue {
        var body: [String: JSONValue] = ["id": .string(item.id), "title": .string(item.title), "reason": .string(item.reason),
                                         "status": .string(item.status), "from": .string(item.source), "createdAt": .string(item.createdAt)]
        if let comment = item.comment { body["comment"] = .string(comment) }
        return .object(body)
    }

    // MARK: - Arguments

    static func folded(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func matches(_ wanted: JSONValue?, _ value: String) -> Bool {
        guard let wanted = wanted?.stringValue, !wanted.isEmpty else { return true }
        return wanted.caseInsensitiveCompare(value) == .orderedSame
    }

    static func required(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw BridgeError.message("Give \(key).") }
        return value
    }

    static func whole(_ arguments: [String: JSONValue], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = arguments[key], raw != .null else { return fallback }
        guard let value = raw.intValue, range.contains(value) else {
            throw BridgeError.message("Give \(key) as a whole number from \(range.lowerBound)\(range.upperBound == Int.max ? " up" : " to \(range.upperBound)").")
        }
        return value
    }

    static func optionalDay(_ arguments: [String: JSONValue], _ key: String) throws -> String? {
        guard let text = arguments[key]?.stringValue, !text.isEmpty else { return nil }
        guard parseDay(text) != nil else { throw BridgeError.message("Give \(key) as yyyy-MM-dd.") }
        return text
    }

    static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    static func day(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
