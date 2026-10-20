import Foundation

/// The list of Macs, which one is selected, and each one's key. Names and addresses are saved in preferences; keys go to the `KeyStore`.
@MainActor
@Observable
final class TargetStore {
    private(set) var targets: [MacTarget] = []
    private(set) var selectedID: UUID?
    private let defaults: UserDefaults
    private let keys: KeyStore
    private static let listKey = "targets.list"
    private static let selectedKey = "targets.selected"

    init(defaults: UserDefaults = .standard, keys: KeyStore) {
        self.defaults = defaults
        self.keys = keys
        if let data = defaults.data(forKey: Self.listKey), let saved = try? JSONDecoder().decode([MacTarget].self, from: data) {
            targets = saved
        }
        if let raw = defaults.string(forKey: Self.selectedKey), let id = UUID(uuidString: raw), targets.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = targets.first?.id
        }
    }

    /// Adds the computers named in the build's `GreenfieldPresetComputers` setting ("name=address name=address"), once, without keys.
    /// Removing one later sticks: the presets are not re-added.
    func seedPresets(_ spec: String?, flag: String = "targets.presetsSeeded") {
        guard let spec, !defaults.bool(forKey: flag) else { return }
        for pair in spec.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !targets.contains(where: { $0.address == parts[1] }) else { continue }
            targets.append(MacTarget(name: parts[0], address: parts[1]))
        }
        if selectedID == nil { selectedID = targets.first?.id }
        defaults.set(true, forKey: flag)
        persist()
    }

    var selected: MacTarget? { targets.first { $0.id == selectedID } }

    func key(for target: MacTarget) -> String? { keys.key(for: target.id) }

    /// Adds or replaces (by id). `key` nil leaves a saved key alone; an empty string removes it. The first Mac added becomes selected.
    func save(_ target: MacTarget, key: String?) throws {
        if let key { try keys.setKey(key, for: target.id) }
        if let index = targets.firstIndex(where: { $0.id == target.id }) { targets[index] = target } else { targets.append(target) }
        if selectedID == nil { selectedID = target.id }
        persist()
    }

    func select(_ id: UUID) {
        guard targets.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
    }

    func remove(_ id: UUID) {
        try? keys.setKey(nil, for: id)
        targets.removeAll { $0.id == id }
        if selectedID == id { selectedID = targets.first?.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(targets) { defaults.set(data, forKey: Self.listKey) }
        defaults.set(selectedID?.uuidString, forKey: Self.selectedKey)
    }
}
