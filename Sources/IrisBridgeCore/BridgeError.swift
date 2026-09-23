import Foundation

public enum BridgeError: LocalizedError, Equatable {
    case message(String), timeout, canceled
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .timeout: return "Your provider took too long. No post was changed. Try again."
        case .canceled: return "Request canceled. Nothing was changed."
        }
    }
}
