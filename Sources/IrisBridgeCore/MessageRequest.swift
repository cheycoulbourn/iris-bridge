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

public struct ImageAttachment: Codable { public var mime: String; public var data: String }

public struct MessageRequest: Codable {
    public var id: String?
    public var provider: String
    public var message: String
    public var context: String?
    public var history: [String]?
    public var skills: [String]?
    public var documents: [String]?
    public var images: [ImageAttachment]?
    public var planMode: Bool?
    public var today: String?
}

public enum MessageValidation {
    public static func parse(_ body: Data) throws -> MessageRequest {
        guard let request = try? JSONDecoder().decode(MessageRequest.self, from: body) else {
            throw BridgeError.message("Could not read this message. Check the text and attachments.")
        }
        guard ["claude", "codex"].contains(request.provider) else { throw BridgeError.message("Choose Claude Code or Codex.") }
        let text = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, request.message.count <= 24_000 else { throw BridgeError.message("Enter a message under 24,000 characters.") }
        if let id = request.id, id.count > 100 { throw BridgeError.message("Invalid request identifier.") }
        let images = request.images ?? []
        guard images.count <= 4 else { throw BridgeError.message("Choose up to four images.") }
        for image in images {
            guard ["image/jpeg", "image/png"].contains(image.mime) else { throw BridgeError.message("Use JPEG or PNG images.") }
            guard let bytes = Data(base64Encoded: image.data) else { throw BridgeError.message("Could not read this message. Check the text and attachments.") }
            guard bytes.count <= 5_000_000 else { throw BridgeError.message("Use images smaller than 5 MB.") }
        }
        return request
    }
}
