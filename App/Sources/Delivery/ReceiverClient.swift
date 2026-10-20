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
        case badKey = "unauthorized"
        case keyNotConfigured = "key_not_configured"
        case secureInput = "secure_input"
        case locked = "screen_locked"
        case needsAccessibility = "accessibility_not_granted"
        case invalidText = "bad_request"
        case tooLarge = "too_large"
        case insertFailed = "insert_failed"
        case other

        var message: String {
            switch self {
            case .badKey: return "This computer asks for a key, or refuses the saved one. Fix it under Advanced in its settings."
            case .keyNotConfigured: return "That computer's input agent is not set up yet. Update or restart it."
            case .secureInput: return "A password field is focused on the computer."
            case .locked: return "The computer's screen is locked."
            case .needsAccessibility: return "The computer's input agent needs Accessibility approval."
            case .invalidText: return "The computer rejected the text."
            case .tooLarge: return "The text is too long for the computer to accept."
            case .insertFailed: return "The computer could not insert the text."
            case .other: return "The computer refused the text."
            }
        }
    }

    /// What `GET /status` reported.
    struct MacStatus: Equatable, Sendable {
        var name = ""
        var version = ""
        var locked = false
        var secureInput = false
        var accessibility = true
        var insertedCount = 0
    }

    enum Health: Equatable, Sendable {
        case ready(MacStatus)
        case wrongKey
        /// The Mac answered 503 `key_not_configured`: an older agent that wants a key and has none yet.
        case keyNotSetOnMac
        case incompatible(String)
        case unreachable(String)
    }

    static let supportedContractMajor = 1
    /// The agent accepts up to 256 KiB per text.
    static let maxBody = 262_144

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
        let payload: [String: String] = ["id": id.uuidString, "text": text, "source": "greenfield"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload), body.count <= Self.maxBody else {
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

    /// `GET /peers`: the compatible computers the agent can see on its tailnet; nil when it does not offer the route.
    func peers(of base: URL, key: String?) async -> [DiscoveredComputer]? {
        var request = URLRequest(url: base.appendingPathComponent("peers"))
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Dictation-Key") }
        if offTailnet(base) { return nil }
        guard let (status, data) = try? await route(for: base).send(request), status == 200 else { return nil }
        return PeerDirectory.parsePeers(data)
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
        let byStatus: [Int: Refusal] = [401: .badKey, 409: .secureInput, 413: .tooLarge, 423: .locked, 400: .invalidText, 422: .invalidText,
                                        503: .needsAccessibility, 500: .insertFailed]
        if let refusal = byStatus[status] { return .refused(refusal) }
        if status == 200 { return .unreachable("The computer answered 200 without an ok body: it is not a text receiver.") }
        return .unreachable("The computer answered HTTP \(status).")
    }

    static func interpretHealth(status: Int, data: Data) -> Health {
        let object = try? JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any] ?? [:]
        if status == 401 { return .wrongKey }
        if status == 503, json["error"] as? String == "key_not_configured" { return .keyNotSetOnMac }
        guard status == 200, json["ok"] as? Bool == true else {
            return .unreachable("HTTP \(status) from /status: not a text receiver.")
        }
        // An agent that states a contract version must be one this app knows; the current agent states none.
        if let contract = json["contract"] as? String, Int(contract.split(separator: ".").first ?? "") != supportedContractMajor {
            return .incompatible("The computer speaks contract \(contract); this app speaks \(supportedContractMajor).x.")
        }
        return .ready(MacStatus(name: json["name"] as? String ?? "", version: json["version"] as? String ?? "",
                                locked: json["screen_locked"] as? Bool ?? json["locked"] as? Bool ?? false,
                                secureInput: json["secure_input"] as? Bool ?? false,
                                accessibility: json["accessibility"] as? Bool ?? true,
                                insertedCount: json["inserted_count"] as? Int ?? 0))
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut: return "The computer did not answer in time."
        case .notConnectedToInternet: return "The phone has no network connection."
        case .cannotFindHost, .dnsLookupFailed: return "The computer's name could not be found."
        case .cannotConnectToHost, .networkConnectionLost: return "The computer could not be reached (is its input agent running?)."
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
