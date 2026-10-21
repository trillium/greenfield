import Foundation
import KitAssist
import KitAssistNet
import KitUI

/// How the shared Assist tab (`AssistView` in the kit) is joined to this app: the words that name this app's helper, what the chosen
/// computer's `GET /status` means for the tab, and the transports for the daemon contract (`mac/docs/assist-pointer.md`).
/// The screens themselves are the kit's; nothing here draws.
enum AssistWiring {
    /// The kit's wording, with the two steps that depend on this app's Mac helper.
    static var strings: AssistStrings {
        var strings = AssistStrings.standard
        strings.turnOnStep = "On that Mac, its owner runs `greenfield-inserter assist on` in Terminal, then check again."
        strings.unsupportedStep = "Update the helper on that Mac (`make -C mac install` there) or see Help > Health, then check again."
        return strings
    }

    /// Said in place of the tools until the chosen computer has answered once. `%@` is the computer's name.
    static let lookingTitle = "Looking at %@…"

    /// What the tab shows for the chosen computer, from the answer its last `GET /status` got. nil while that computer has not answered
    /// yet: the tab says it is looking instead of claiming the computer is off or away.
    static func availability(selected: MacTarget?, answer: ReceiverClient.Health?) -> AssistAvailability? {
        guard selected != nil else { return .noComputer }
        guard let answer else { return nil }
        switch answer {
        case .unreachable:
            return .unreachable
        case .wrongKey, .keyNotSetOnMac, .incompatible:
            // An agent that wants a key, has none set up, or speaks another version has no assist tools this app can use.
            return .unsupported
        case .ready(let status):
            if AppVersion.verdict(for: status) != .compatible { return .unsupported }
            return AssistAvailability(status: status.assist)
        }
    }

    /// The headers every assist request carries: the app's version, which the helper's compatibility rule reads.
    static func headers() -> [String: String] {
        AppVersion.current.map { [AppVersion.header: $0.description] } ?? [:]
    }

    /// The phone's side of the daemon contract for one computer; nil when its address cannot be reached at all.
    static func transports(for target: MacTarget, http: AssistHTTPTransport = AppAssistHTTPTransport()) -> AssistTransports? {
        guard let base = target.baseURL else { return nil }
        let client = AssistHTTPClient(baseURL: base, headers: headers(), transport: http)
        return AssistTransports(windows: client, pointer: UDPPointerTransport(opener: client))
    }
}

/// The window list and the pointer path for one computer.
struct AssistTransports {
    let windows: WindowsClient
    let pointer: PointerTransport
}

/// The kit's HTTP seam on this app's own routing: tailnet addresses (100.x) go over plain TCP, because App Transport Security cannot be
/// told to allow an address range, and names go through URLSession. Off the tailnet the answer is the same "no route" the text path
/// gives. The raw TCP path does not hand back response headers, so a 429 carries no Retry-After here (the screens do not use it).
struct AppAssistHTTPTransport: AssistHTTPTransport {
    var named: HTTPTransport = URLSessionTransport(session: .dictation)
    var address: HTTPTransport = SocketTransport()
    var tailnetConnected: @Sendable () -> Bool = Tailnet.isConnected

    func send(_ request: URLRequest) async throws -> AssistHTTPResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        let host = url.host ?? ""
        if Tailnet.needsTailnet(host), !tailnetConnected() { throw URLError(.notConnectedToInternet) }
        let route = Tailnet.isIPv4Literal(host) ? address : named
        let (status, data) = try await route.send(request)
        return AssistHTTPResponse(status: status, body: data)
    }
}

/// Keeps the transports of the chosen computer, so the pointer path is made once per computer and not on every redraw of the tab.
@MainActor
final class AssistTransportCache {
    private var held: (target: MacTarget, transports: AssistTransports?)?

    func transports(for target: MacTarget,
                    make: (MacTarget) -> AssistTransports? = { AssistWiring.transports(for: $0) }) -> AssistTransports? {
        if let held, held.target == target { return held.transports }
        let made = make(target)
        held = (target, made)
        return made
    }
}
