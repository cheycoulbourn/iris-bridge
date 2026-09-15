import Foundation

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public final class HTTPRequestParser {
    public enum Outcome { case needMore, complete(HTTPRequest), invalid(String), tooLarge }
    private var buffer = Data()
    private let maxBody: Int
    private let maxHead = 64 * 1024
    public init(maxBody: Int = 28_000_000) { self.maxBody = maxBody }
    public func feed(_ data: Data) -> Outcome {
        buffer.append(data)
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .invalid("Header too large") : .needMore
        }
        guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else { return .invalid("Header not UTF-8") }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              ["GET", "POST", "DELETE"].contains(String(requestLine[0])), requestLine[1].hasPrefix("/") else { return .invalid("Bad request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("Bad header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("Bad content length") }
        guard length <= maxBody else { return .tooLarge }
        let bodyStart = headEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .needMore }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body))
    }
}

public struct HTTPResponse {
    public var status: Int
    public var body: Data
    public init(status: Int, json: Any) {
        self.status = status
        body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    public init(status: Int, error: String) { self.init(status: status, json: ["error": error]) }
    public init(status: Int, data: Data) { self.status = status; body = data }
    private static let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                                  409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error",
                                  502: "Bad Gateway", 504: "Gateway Timeout"]
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
