import Foundation

/// The reachability dot beside each Mac, from `GET /status`.
@MainActor
@Observable
final class TargetHealth {
    enum State: Equatable {
        case unknown, checking
        case ready(ReceiverClient.MacStatus), notice(String), noKey, wrongKey, keyNotSetOnMac, incompatible(String), unreachable(String)

        var summary: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking"
            case .ready(let status): return status.version.isEmpty ? "Ready" : "Ready (agent \(status.version))"
            case .notice(let message): return message
            case .noKey: return "Enter this computer's key"
            case .wrongKey: return "Wrong key"
            case .keyNotSetOnMac: return "No key set on that computer yet"
            case .incompatible(let message): return message
            case .unreachable(let message): return message
            }
        }
    }

    private(set) var states: [UUID: State] = [:]
    private let service: DeliveryService

    init(service: DeliveryService) { self.service = service }

    func state(for target: MacTarget) -> State { states[target.id] ?? .unknown }

    func refresh(_ target: MacTarget) async {
        guard let key = service.targets.key(for: target), !key.isEmpty else {
            states[target.id] = .noKey
            return
        }
        states[target.id] = .checking
        states[target.id] = Self.state(from: await service.health(of: target))
    }

    func refreshAll() async {
        for target in service.targets.targets { await refresh(target) }
    }

    static func state(from health: ReceiverClient.Health) -> State {
        switch health {
        case .ready(let status):
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
