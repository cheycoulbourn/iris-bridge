import Foundation
@testable import IrisBridgeCore

/// Replays a recorded provider transcript (`Fixtures/<name>.jsonl`) instead of running a CLI. Each line is
/// `{"dir":"in","obj":…}` (a line the helper must write next: matched on `type` and, for control requests,
/// `request.subtype`), `{"dir":"out","obj":…}` (a line the CLI printed) or `{"dir":"exit","status":…,
/// "stderr":…}`. A string `"@file.json"` anywhere in an `out` line is replaced by that fixture's JSON. What
/// the CLI printed before the first `in` is printed at launch; each matching write releases the lines up to
/// the next `in`. A write that matches nothing is only recorded, so extra control requests are harmless.
final class ScriptedLauncher: ProcessLauncher {
    private(set) var commands: [ProviderCommand] = []
    private(set) var processes: [ScriptedProcess] = []
    private var scripts: [[JSONValue]]

    /// One transcript per launch, in order.
    init(_ fixtures: String...) {
        scripts = fixtures.map(ScriptedLauncher.load)
    }

    static func load(_ name: String) -> [JSONValue] {
        let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
        return (try! String(contentsOf: url, encoding: .utf8)).split(separator: "\n").map { try! JSONValue.decode(Data($0.utf8)) }
    }

    func launch(_ command: ProviderCommand, line: @escaping (Data) -> Void, exit: @escaping (Int32, String) -> Void) throws -> ProviderProcess {
        commands.append(command)
        let process = ScriptedProcess(script: scripts.isEmpty ? [] : scripts.removeFirst(), line: line, exit: exit)
        processes.append(process)
        process.run()
        if let input = command.input { process.received(input) }
        return process
    }
}

final class ScriptedProcess: ProviderProcess {
    private let lock = NSLock()
    private var script: [JSONValue]
    private let line: (Data) -> Void
    private let exit: (Int32, String) -> Void
    private var exited = false
    private(set) var written: [JSONValue] = []

    init(script: [JSONValue], line: @escaping (Data) -> Void, exit: @escaping (Int32, String) -> Void) {
        self.script = script; self.line = line; self.exit = exit
    }

    /// Everything the helper wrote, in order.
    var writes: [JSONValue] { lock.lock(); defer { lock.unlock() }; return written }

    func write(_ data: Data) { received(data) }

    func received(_ data: Data) {
        let value = (try? JSONValue.decode(data)) ?? .string(String(decoding: data, as: UTF8.self))
        lock.lock()
        written.append(value)
        let matches = script.first.map { Self.matches($0, value) } ?? false
        if matches { script.removeFirst() }
        lock.unlock()
        if matches { run() }
    }

    func closeInput() { finish(0, "") }
    func terminate() { finish(143, "") }

    /// Plays `out` and `exit` lines until the next `in`.
    func run() {
        while true {
            lock.lock()
            guard let next = script.first, next["dir"] != "in" else { lock.unlock(); return }
            script.removeFirst()
            lock.unlock()
            if next["dir"] == "exit" { finish(Int32(next["status"]?.intValue ?? 0), next["stderr"]?.stringValue ?? ""); return }
            line(Self.expand(next["obj"] ?? .null).encoded())
        }
    }

    private func finish(_ status: Int32, _ stderr: String) {
        lock.lock()
        guard !exited else { lock.unlock(); return }
        exited = true
        lock.unlock()
        exit(status, stderr)
    }

    private static func matches(_ step: JSONValue, _ value: JSONValue) -> Bool {
        guard step["dir"] == "in" else { return false }
        let expected = step["obj"]
        if expected?["type"] == "stdin" { return true }
        guard expected?["type"] == value["type"] else { return false }
        if let subtype = expected?["request"]?["subtype"] { return value["request"]?["subtype"] == subtype }
        return true
    }

    private static func expand(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text) where text.hasPrefix("@"):
            let name = String(text.dropFirst()).replacingOccurrences(of: ".json", with: "")
            let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
            return try! JSONValue.decode(Data(contentsOf: url))
        case .object(let object): return .object(object.mapValues(expand))
        case .array(let array): return .array(array.map(expand))
        default: return value
        }
    }
}

/// Collects a session's events and waits for the ones a test needs.
final class EventRecorder {
    private let lock = NSLock()
    private var events: [ProviderEvent] = []

    func record(_ event: ProviderEvent) { lock.lock(); events.append(event); lock.unlock() }

    var all: [ProviderEvent] { lock.lock(); defer { lock.unlock() }; return events }

    /// Turn events for one turn, in order.
    func turn(_ id: String) -> [TurnEvent] {
        all.compactMap { if case .turn(id, let event) = $0 { return event }; return nil }
    }

    /// Waits until `condition` holds or `timeout` passes.
    @discardableResult
    func wait(timeout: TimeInterval = 5, until condition: ([ProviderEvent]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(all) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition(all)
    }

    func waitForEnd(of turnId: String, timeout: TimeInterval = 5) -> TurnEvent? {
        wait(timeout: timeout) { events in events.contains { if case .turn(turnId, let event) = $0 { return event.isTerminal }; return false } }
        return turn(turnId).last
    }
}
