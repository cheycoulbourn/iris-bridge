import Foundation

/// The two chat providers a Mac can run. The raw value is the wire name in every v2 and v3 message.
public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    /// What the app calls the provider in sentences: "Claude" or "ChatGPT".
    public var displayName: String { self == .claude ? "Claude" : "ChatGPT" }
}
