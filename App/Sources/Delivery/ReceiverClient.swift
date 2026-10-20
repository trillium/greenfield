import Foundation

/// Talks to a Mac receiver (docs/mac-contract.md). One request per call; never retries by itself: the outbox decides about resends.
struct ReceiverClient: Sendable {
    /// What happened to one `POST /text`.
    enum SendOutcome: Equatable, Sendable {
        /// The Mac inserted the text (or had already inserted this id). `macMs` is the receiver's own time.
        case delivered(duplicate: Bool, macMs: Int?)
        /// The Mac answered and refused. The text was not inserted.
        case refused(Refusal)
        /// No usable answer: the Mac is off, the network is down, or the request timed out. The text may or may not have arrived.
        case unreachable(String)
    }

    enum Refusal: String, Equatable, Sendable {
        case badKey = "bad_key"
        case secureInput = "secure_input"
        case locked
        case invalidText = "invalid_text"
        case tooLarge = "too_large"
        case rateLimited = "rate_limited"
        case other

        var message: String {
            switch self {
            case .badKey: return "The key for this Mac is wrong."
            case .secureInput: return "A password field is focused on the Mac."
            case .locked: return "The Mac is locked."
            case .invalidText: return "The Mac rejected the text."
            case .tooLarge: return "The text is too long for the Mac to accept."
            case .rateLimited: return "The Mac is rate limiting requests. Try again in a moment."
            case .other: return "The Mac refused the text."
            }
        }
    }

    /// What `GET /status` showed.
    enum Health: Equatable, Sendable {
        case ready(name: String, locked: Bool, secureInput: Bool)
        case wrongKey
        case incompatible(String)
        case unreachable(String)
    }

    static let supportedContractMajor = 1
    static let maxBody = 4096

    /// For names. Tailnet addresses (100.x) go through `addressTransport`, which ATS does not govern.
    var transport: HTTPTransport
    var addressTransport: HTTPTransport = SocketTransport()
    /// Whether this phone is on the tailnet; injectable for tests.
    var tailnetConnected: @Sendable () -> Bool = Tailnet.isConnected

    init(session: URLSession = .dictation, addressTransport: HTTPTransport = SocketTransport(),
         tailnetConnected: @escaping @Sendable () -> Bool = Tailnet.isConnected) {
        transport = URLSessionTransport(session: session)
        self.addressTransport = addressTransport
        self.tailnetConnected = tailnetConnected
    }

    private func route(for url: URL) -> HTTPTransport {
        Tailnet.isIPv4Literal(url.host ?? "") ? addressTransport : transport
    }

    /// A clear refusal, instead of a timeout, when the Mac can only be reached through a tailnet this phone is not on.
    private func offTailnet(_ url: URL) -> Bool {
        Tailnet.needsTailnet(url.host ?? "") && !tailnetConnected()
    }

    func send(id: UUID, text: String, to base: URL, key: String?) async -> (outcome: SendOutcome, networkMs: Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        var request = URLRequest(url: base.appendingPathComponent("text"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Dictation-Key") }
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": id.uuidString, "text": text]), body.count <= Self.maxBody else {
            return (.refused(.tooLarge), 0)
        }
        request.httpBody = body
        if offTailnet(base) { return (.unreachable(Tailnet.notConnectedMessage), 0) }
        do {
            let (status, data) = try await route(for: base).send(request)
            return (Self.interpret(status: status, data: data), elapsed())
        } catch {
            return (.unreachable(Self.describe(error)), elapsed())
        }
    }

    func health(of base: URL, key: String?) async -> Health {
        var request = URLRequest(url: base.appendingPathComponent("status"))
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Dictation-Key") }
        if offTailnet(base) { return .unreachable(Tailnet.notConnectedMessage) }
        do {
            let (status, data) = try await route(for: base).send(request)
            return Self.interpretHealth(status: status, data: data)
        } catch {
            return .unreachable(Self.describe(error))
        }
    }

    static func interpret(status: Int, data: Data) -> SendOutcome {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 200, json["ok"] as? Bool == true {
            return .delivered(duplicate: json["duplicate"] as? Bool ?? false, macMs: json["ms"] as? Int)
        }
        if let error = json["error"] as? String, let refusal = Refusal(rawValue: error) { return .refused(refusal) }
        switch status {
        case 401: return .refused(.badKey)
        case 409: return .refused(.secureInput)
        case 413: return .refused(.tooLarge)
        case 422: return .refused(.invalidText)
        case 423: return .refused(.locked)
        case 429: return .refused(.rateLimited)
        case 200: return .unreachable("The Mac answered 200 without an ok body: it is not a text receiver.")
        default: return .unreachable("The Mac answered HTTP \(status).")
        }
    }

    static func interpretHealth(status: Int, data: Data) -> Health {
        if status == 401 { return .wrongKey }
        let object = try? JSONSerialization.jsonObject(with: data)
        guard status == 200, let json = object as? [String: Any], json["ok"] as? Bool == true else {
            return .unreachable("HTTP \(status) from /status: not a text receiver.")
        }
        let contract = json["contract"] as? String ?? "?"
        guard let major = Int(contract.split(separator: ".").first ?? ""), major == supportedContractMajor else {
            return .incompatible("Receiver speaks contract \(contract); this app speaks \(supportedContractMajor).x.")
        }
        return .ready(name: json["name"] as? String ?? "", locked: json["locked"] as? Bool ?? false,
                      secureInput: json["secure_input"] as? Bool ?? false)
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut: return "The Mac did not answer in time."
        case .notConnectedToInternet: return "The phone has no network connection."
        case .cannotFindHost, .dnsLookupFailed: return "The Mac's name could not be found."
        case .cannotConnectToHost, .networkConnectionLost: return "The Mac could not be reached (is its receiver running?)."
        case .appTransportSecurityRequiresSecureConnection: return "Blocked: plain http is only allowed to *.ts.net and local hosts."
        default: return urlError.localizedDescription
        }
    }
}

extension URLSession {
    /// Short timeouts: a Mac on the tailnet answers in milliseconds, and the user is watching.
    static let dictation: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
