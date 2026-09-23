import Foundation
@testable import IrisBridgeCore

/// Stands in for the connected apps: records what the helper sent, and can answer it.
final class FakeOutbox: StreamOutbox {
    private let lock = NSLock()
    private var _broadcasts: [JSONValue] = []
    private var _sentToOne: [JSONValue] = []
    var connected = true
    /// Called with every message sent to one device, on a background queue, as an app would answer it.
    var onSendToOne: ((JSONValue) -> Void)?

    var broadcasts: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _broadcasts }
    var sentToOne: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _sentToOne }
    var hasClients: Bool { connected }

    func broadcast(_ message: JSONValue) { lock.lock(); _broadcasts.append(message); lock.unlock() }

    func sendToOne(_ message: JSONValue) -> Bool {
        guard connected else { return false }
        lock.lock(); _sentToOne.append(message); lock.unlock()
        if let onSendToOne { DispatchQueue.global().async { onSendToOne(message) } }
        return true
    }
}
