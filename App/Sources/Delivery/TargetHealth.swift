import Foundation

/// The reachability dot beside each Mac, from `GET /status`.
@MainActor
@Observable
final class TargetHealth {
    enum State: Equatable {
        case unknown, checking
        case ready(ReceiverClient.MacStatus), notice(String), wrongKey, keyNotSetOnMac, incompatible(String), unreachable(String)

        var summary: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking"
            case .ready(let status): return status.version.isEmpty ? "Ready" : "Ready (agent \(status.version))"
            case .notice(let message): return message
            case .wrongKey: return "Will not take text from this phone (see Health)"
            case .keyNotSetOnMac: return "Its input agent is not set up yet"
            case .incompatible(let message): return message
            case .unreachable(let message): return message
            }
        }
    }

    private(set) var states: [UUID: State] = [:]
    /// The last `GET /status` answer for each computer, for the Health screen.
    private(set) var answers: [UUID: ReceiverClient.Health] = [:]
    private let service: DeliveryService

    init(service: DeliveryService) { self.service = service }

    func state(for target: MacTarget) -> State { states[target.id] ?? .unknown }

    func refresh(_ target: MacTarget) async {
        states[target.id] = .checking
        let answer = await service.health(of: target)
        answers[target.id] = answer
        states[target.id] = Self.state(from: answer)
    }

    func refreshAll() async {
        for target in service.targets.targets { await refresh(target) }
    }

    /// "Update the Mac daemon" or "Update the app" when the contract's rule fails, else nil.
    static func compatibilityProblem(_ status: ReceiverClient.MacStatus) -> String? {
        switch Compatibility.judge(app: Compatibility.appVersion, agent: status.version, minClient: status.minClientVersion,
                                   minimumAgent: Compatibility.minimumAgent) {
        case .updateAgent: return "Update the Mac daemon (it is \(status.version.isEmpty ? "too old" : status.version))"
        case .updateApp: return "Update the app (that computer needs a newer one)"
        case .compatible: return nil
        }
    }

    static func state(from health: ReceiverClient.Health) -> State {
        switch health {
        case .ready(let status):
            if let problem = compatibilityProblem(status) { return .incompatible(problem) }
            if !status.accessibility { return .notice("Needs Accessibility approval on that computer") }
            if status.locked { return .notice("Ready, but its screen is locked") }
            if status.secureInput { return .notice("Ready, but a password field is focused") }
            return .ready(status)
        case .wrongKey: return .wrongKey
        case .keyNotSetOnMac: return .keyNotSetOnMac
        case .incompatible(let message): return .incompatible(message)
        case .unreachable(let message): return .unreachable(message)
        }
    }
}
