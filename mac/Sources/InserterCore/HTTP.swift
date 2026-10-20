import Foundation

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data
    /// True when the TCP peer is on this Mac (set by the server, never taken from the request).
    public var fromLoopback: Bool

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(),
                fromLoopback: Bool = false) {
        self.method = method
        self.path = path
        self.fromLoopback = fromLoopback
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    public static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(status, ["ok": false, "error": code, "message": message])
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 423: return "Locked"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public enum HTTPParseResult: Equatable {
    case incomplete
    case complete(HTTPRequest)
    case invalid(HTTPResponse)
}

/// A deliberately small HTTP/1.1 request parser: no chunked bodies, no keep-alive.
public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ buffer: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else {
            if buffer.count > maxHeaderBytes {
                return .invalid(.error(431, "header_too_large", "request headers too large"))
            }
            return .incomplete
        }
        if headEnd.lowerBound > maxHeaderBytes {
            return .invalid(.error(431, "header_too_large", "request headers too large"))
        }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return .invalid(.error(400, "bad_request", "headers are not valid UTF-8"))
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .invalid(.error(400, "bad_request", "malformed request line"))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(.error(400, "bad_request", "malformed header"))
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(.error(501, "not_implemented", "chunked bodies are not supported"))
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else {
                return .invalid(.error(400, "bad_request", "bad Content-Length"))
            }
            if n > maxBodyBytes { return .invalid(.error(413, "too_large", "body too large")) }
            length = n
        } else if parts[0].uppercased() == "POST" {
            return .invalid(.error(411, "length_required", "Content-Length is required"))
        }
        let bodyStart = headEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        // Query strings are ignored; routing is by path only.
        let path = String(parts[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: path, headers: headers, body: Data(body)))
    }
}
