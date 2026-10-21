import Foundation

/// The sound models on this phone and which one is active. The model bundled in the app is only the fallback: once a pack has been
/// installed and chosen, the detector is built from it, so the model changes without rebuilding the app.
///
/// Nothing half-installed is ever visible: a pack is parsed, loaded in the detector library and written (temp file, then rename)
/// before the index changes, and a failure at any step leaves the previous model active.
final class ParrotModelStore: @unchecked Sendable {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let labels: [String]
        let patterns: [String]
        let installedAt: Date
    }

    /// What the detector is built from.
    struct Source: Equatable {
        let name: String
        let model: [UInt8]
        /// nil = the patterns built into the detector library (the bundled model's).
        let patternsJSON: String?
        let isBundled: Bool
    }

    private struct Index: Codable {
        var entries: [Entry] = []
        var activeID: String?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case wrongLabels(expected: [String], found: [String])
        case detectorRefused(String)
        case storage(String)
        case noBundledModel

        var description: String {
            switch self {
            case .unknown(let id): return "No installed model has the id \(id)."
            case .wrongLabels: return "The model's own sounds do not match the pack's list."
            case .detectorRefused(let why): return "The detector would not load this model: \(why)"
            case .storage(let why): return "Could not save the model: \(why)"
            case .noBundledModel: return "The app has no bundled model; run 'make core' and rebuild."
            }
        }
    }

    /// Loads a candidate the way the app will and returns its class names.
    typealias Validator = @Sendable (_ model: [UInt8], _ patternsJSON: String) throws -> [String]

    static let didChange = Notification.Name("ParrotModelStoreDidChange")
    static let bundledName = "Bundled model"
    /// Pattern names of the bundled model's built-in set, for the rule editor.
    static let bundledPatterns = ["clap", "hiss", "kitty-cmere", "lip-pop", "piggy-oink", "shh", "tongue-click"]

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sounds/Models", isDirectory: true)
    }

    static let detectorValidator: Validator = { model, patterns in
        do { return try SoundDetector(model: model, patternsJSON: patterns).labels } catch { throw Failure.detectorRefused("\(error)") }
    }

    private let directory: URL
    private let validator: Validator
    private let bundled: @Sendable () throws -> [UInt8]
    private let lock = NSLock()

    init(directory: URL = ParrotModelStore.defaultDirectory, validator: @escaping Validator = ParrotModelStore.detectorValidator,
         bundled: @escaping @Sendable () throws -> [UInt8] = ParrotModelStore.bundledModel) {
        self.directory = directory
        self.validator = validator
        self.bundled = bundled
    }

    static func bundledModel() throws -> [UInt8] {
        guard let url = Bundle.main.url(forResource: "parrot-model", withExtension: "bin") else { throw Failure.noBundledModel }
        return [UInt8](try Data(contentsOf: url))
    }

    func list() -> [Entry] { lock.withLock { readIndex().entries } }
    var activeID: String? { lock.withLock { readIndex().activeID } }

    /// The model to detect with: the chosen pack if it reads back intact, otherwise the bundled one.
    func source() throws -> Source {
        let chosen: Source? = lock.withLock {
            let index = readIndex()
            guard let id = index.activeID, let entry = index.entries.first(where: { $0.id == id }),
                  let data = try? Data(contentsOf: file(for: id)), let pack = try? ParrotModelPack(data: data) else { return nil }
            return Source(name: entry.name, model: pack.model, patternsJSON: pack.patternsJSON, isBundled: false)
        }
        if let chosen { return chosen }
        return Source(name: Self.bundledName, model: try bundled(), patternsJSON: nil, isBundled: true)
    }

    /// Pattern names the active model can fire.
    func activePatterns() -> [String] {
        let index = lock.withLock { readIndex() }
        guard let id = index.activeID, let entry = index.entries.first(where: { $0.id == id }) else { return Self.bundledPatterns }
        return entry.patterns
    }

    /// Parses, loads and saves a pack; activates it unless told not to.
    @discardableResult
    func install(_ data: Data, activate: Bool = true) throws -> Entry {
        let pack = try ParrotModelPack(data: data)
        let found = try validator(pack.model, pack.patternsJSON)
        guard found == pack.manifest.labels else { throw Failure.wrongLabels(expected: pack.manifest.labels, found: found) }
        let entry = Entry(id: String(pack.manifest.modelSha256.prefix(12)), name: pack.manifest.name, labels: pack.manifest.labels,
                          patterns: pack.patternNames, installedAt: Date())
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(data, to: file(for: entry.id))
            var index = readIndex()
            index.entries.removeAll { $0.id == entry.id }
            index.entries.append(entry)
            if activate { index.activeID = entry.id }
            try save(index)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return entry
    }

    /// Chooses an installed model, or nil to go back to the bundled one.
    func activate(_ id: String?) throws {
        try lock.withLock {
            var index = readIndex()
            if let id, !index.entries.contains(where: { $0.id == id }) { throw Failure.unknown(id) }
            index.activeID = id
            try save(index)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func remove(_ id: String) throws {
        try lock.withLock {
            var index = readIndex()
            guard index.entries.contains(where: { $0.id == id }) else { throw Failure.unknown(id) }
            index.entries.removeAll { $0.id == id }
            if index.activeID == id { index.activeID = nil }
            try save(index)
            try? FileManager.default.removeItem(at: file(for: id))
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Storage

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func file(for id: String) -> URL { directory.appendingPathComponent("\(id).parrotpack") }

    private func readIndex() -> Index {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL), let index = try? decoder.decode(Index.self, from: data) else { return Index() }
        return index
    }

    private func save(_ index: Index) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(index), to: indexURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw Failure.storage("\(error)")
        }
    }
}
