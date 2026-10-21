import Foundation
import Network
import Observation

/// A compatible computer found on the tailnet or the local network, not yet in the list.
struct DiscoveredComputer: Equatable, Identifiable, Sendable {
    enum Source: String, Sendable { case peers, bonjour, link }

    let name: String
    /// Tailnet name or address (optionally with :port) to put in the list.
    let address: String
    var version = ""
    let source: Source
    var id: String { address.lowercased() }

    /// The computer as a list entry.
    var target: MacTarget { MacTarget(name: name, address: address) }
}

/// Finds computers so a new user needs no setup beyond one seed: a computer already in the list that answers `GET /peers`
/// (the agent probes its own tailnet peers and returns the ones running Greenfield), Bonjour `_greenfield._tcp` on the local
/// network, or a `greenfield://add?name=...&address=...` link (what a QR code shown by the installer opens).
@MainActor
@Observable
final class PeerDirectory {
    static let bonjourType = "_greenfield._tcp"

    private(set) var discovered: [DiscoveredComputer] = []
    private(set) var searching = false
    private(set) var lastError: String?
    /// What the Bonjour browser says about the local-network permission (iOS has no direct query: a browse that is refused reports it).
    private(set) var localNetwork: LocalNetworkState = .unknown
    private var browser: NWBrowser?
    private let service: DeliveryService

    init(service: DeliveryService) { self.service = service }

    /// Asks every computer in the list for its peers and merges the answers with what Bonjour has found.
    func refresh() async {
        searching = true
        defer { searching = false }
        lastError = nil
        var found: [DiscoveredComputer] = discovered.filter { $0.source == .bonjour }
        for target in service.targets.targets {
            guard let peers = await service.peers(of: target) else { continue }
            found.append(contentsOf: peers)
        }
        discovered = Self.unique(found, excluding: service.targets.targets)
    }

    /// Starts listening for Bonjour announcements (the system asks for local-network permission the first time).
    func startBonjour() {
        guard browser == nil, !UserDefaults.standard.bool(forKey: "ui-test-isolated") else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            let permission = Self.permission(for: state)
            Task { @MainActor in if let permission { self?.localNetwork = permission } }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.bonjourFound(names) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// `ready` means the system let the browse run; a policy-denied DNS error (-65570) means the permission is off.
    nonisolated static func permission(for state: NWBrowser.State) -> LocalNetworkState? {
        switch state {
        case .ready: return .granted
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == -65_570 { return .denied }
            return nil
        default: return nil
        }
    }

    /// With nothing in the list, a single compatible computer found is added and chosen: nobody types an address.
    /// With computers already listed, exactly one that answered and is compatible is chosen if nothing usable is chosen yet.
    @discardableResult
    func chooseTheOnlyComputer(health: TargetHealth) -> MacTarget? {
        let targets = service.targets
        if targets.targets.isEmpty, discovered.count == 1, let only = discovered.first {
            add(only)
            if let added = targets.targets.first { targets.select(added.id) }
            return targets.selected
        }
        let usable = targets.targets.filter { target in
            if case .ready = health.state(for: target) { return true }
            return false
        }
        guard usable.count == 1, let only = usable.first, targets.selectedID != only.id else { return nil }
        if let current = targets.selected, case .ready = health.state(for: current) { return nil }
        targets.select(only.id)
        return only
    }

    func stopBonjour() {
        browser?.cancel()
        browser = nil
    }

    func bonjourFound(_ names: [String]) {
        let bonjour = names.map { DiscoveredComputer(name: $0, address: Self.localAddress(for: $0), source: .bonjour) }
        let others = discovered.filter { $0.source != .bonjour }
        discovered = Self.unique(others + bonjour, excluding: service.targets.targets)
    }

    /// Adds a computer from a discovery result or a link. No key: tailnet identity is the credential.
    func add(_ computer: DiscoveredComputer) {
        try? service.targets.save(computer.target, key: nil)
        discovered.removeAll { $0.id == computer.id }
    }

    /// `greenfield://add?name=mini0&address=mini0.example.ts.net`: the seed a QR code carries.
    func handle(link url: URL) -> DiscoveredComputer? {
        guard url.scheme == "greenfield", url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "address" })?.value, !address.isEmpty else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? address
        let computer = DiscoveredComputer(name: name, address: address, source: .link)
        guard computer.target.isValid else { return nil }
        add(computer)
        return computer
    }

    nonisolated static func localAddress(for serviceName: String) -> String {
        serviceName.lowercased().replacingOccurrences(of: " ", with: "-") + ".local"
    }

    /// One entry per address, skipping computers already in the list.
    nonisolated static func unique(_ found: [DiscoveredComputer], excluding known: [MacTarget]) -> [DiscoveredComputer] {
        let have = Set(known.map { $0.address.lowercased() })
        var seen = Set<String>()
        return found.filter { have.contains($0.id) == false && seen.insert($0.id).inserted }
    }

    /// Reads `GET /peers`: `{"ok": true, "peers": [{"name", "address", "version"}]}`. Unknown fields are ignored.
    nonisolated static func parsePeers(_ data: Data) -> [DiscoveredComputer] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let peers = json["peers"] as? [[String: Any]] else { return [] }
        return peers.compactMap { peer in
            guard let address = (peer["address"] as? String) ?? (peer["dns_name"] as? String), !address.isEmpty else { return nil }
            let name = (peer["name"] as? String) ?? address
            return DiscoveredComputer(name: name, address: address.hasSuffix(".") ? String(address.dropLast()) : address,
                                      version: peer["version"] as? String ?? "", source: .peers)
        }
    }
}
