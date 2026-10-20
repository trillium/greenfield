import Foundation

/// The reachability dot beside each Mac, from `GET /status`.
@MainActor
@Observable
final class TargetHealth {
    enum State: Equatable {
        case unknown, checking
        case ready, notice(String), wrongKey, incompatible(String), unreachable(String)

        var summary: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking"
            case .ready: return "Ready"
            case .notice(let message): return message
            case .wrongKey: return "Wrong key"
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
        states[target.id] = .checking
        states[target.id] = Self.state(from: await service.health(of: target))
    }

    func refreshAll() async {
        for target in service.targets.targets { await refresh(target) }
    }

    static func state(from health: ReceiverClient.Health) -> State {
        switch health {
        case .ready(_, let locked, let secure):
            if locked { return .notice("Ready, but the Mac is locked") }
            if secure { return .notice("Ready, but a password field is focused") }
            return .ready
        case .wrongKey: return .wrongKey
        case .incompatible(let message): return .incompatible(message)
        case .unreachable(let message): return .unreachable(message)
        }
    }
}
