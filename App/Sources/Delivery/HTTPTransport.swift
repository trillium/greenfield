import Foundation
import Network

/// Sends one HTTP request and returns the status and body. Two implementations: `URLSession` for names, and a plain TCP one for
/// tailnet addresses (100.x), because App Transport Security cannot be told to allow an address range and a blanket exception
/// would switch it off for everything.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, data: Data)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Minimal HTTP/1.1 over `NWConnection`: one request, `Connection: close`, read to the end. Only for the receiver contract
/// (small JSON bodies); not a general client.
struct SocketTransport: HTTPTransport {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var timeout: TimeInterval = 8

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        guard let url = request.url, let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw Failure(message: "This phone could not work out how to reach that computer.")
        }
        let wire = Self.encode(request, host: host, port: Int(port.rawValue))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let exchange = Exchange(connection: connection)
        return try await withTaskCancellationHandler {
            try await exchange.run(wire, timeout: timeout)
        } onCancel: {
            exchange.fail(Failure(message: "cancelled"))
        }
    }

    static func encode(_ request: URLRequest, host: String, port: Int) -> Data {
        var target = (request.url?.path.isEmpty ?? true) ? "/" : request.url!.path
        // The assist window list asks `?since=&epoch=`; a request line without its query would always get the full list.
        let parts = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        if let query = parts?.percentEncodedQuery, !query.isEmpty { target += "?" + query }
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n"
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "content-length" {
            head += "\(name): \(value)\r\n"
        }
        let body = request.httpBody ?? Data()
        if request.httpMethod == "POST" || !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    /// Splits a raw response into status and body. Returns nil until the header block is complete.
    static func parse(_ raw: Data) -> (status: Int, body: Data)? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: raw[raw.startIndex..<split.lowerBound], encoding: .utf8) ?? ""
        let parts = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return (status, Data(raw[split.upperBound...]))
    }
}

/// One connection's lifetime. Resumes its continuation exactly once, whichever of reply, error or timeout comes first.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(status: Int, data: Data), Error>?
    private var received = Data()
    private var finished = false

    init(connection: NWConnection) { self.connection = connection }

    func run(_ wire: Data, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        try await withCheckedThrowingContinuation { (next: CheckedContinuation<(status: Int, data: Data), Error>) in
            lock.lock()
            continuation = next
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.connection.send(content: wire, completion: .contentProcessed { error in
                        if let error { self?.fail(error) } else { self?.readMore() }
                    })
                case .failed(let error): self?.fail(error)
                case .waiting(let error): self?.fail(error)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(URLError(.timedOut))
            }
        }
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            if let error { return self.fail(error) }
            if complete { return self.finish() }
            self.readMore()
        }
    }

    private func finish() {
        guard let parsed = SocketTransport.parse(received) else { return fail(URLError(.badServerResponse)) }
        complete(.success((parsed.status, parsed.body)))
    }

    func fail(_ error: Error) { complete(.failure(Self.readable(error))) }

    /// Network.framework errors as the URL errors the client already explains.
    static func readable(_ error: Error) -> Error {
        guard case NWError.posix(let code) = error else { return error }
        switch code {
        case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN: return URLError(.cannotConnectToHost)
        case .ETIMEDOUT: return URLError(.timedOut)
        default: return error
        }
    }

    private func complete(_ result: Result<(status: Int, data: Data), Error>) {
        lock.lock()
        guard !finished, let next = continuation else {
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        lock.unlock()
        connection.cancel()
        next.resume(with: result)
    }
}
