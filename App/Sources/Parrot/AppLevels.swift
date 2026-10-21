import Foundation
import ParrotKit

/// This app's side of the shared Levels screen (ParrotKit): where the levels are kept, which sounds the active model has, and the one
/// thing the kit cannot know, how this app's detector hears them. The detector is built from the levels (`setup(for:)`), the screen's
/// readings come from the detector's listener, and a change on the screen rebuilds the detector (`apply`).
@MainActor
final class AppLevels: SoundLevelsProvider {
    /// What the detector is built with: its pattern set and the gain applied to its samples.
    struct Setup: Equatable {
        let patternsJSON: String?
        let gain: Double
    }

    /// `Application Support/Sounds/levels.json`: in the app's sandbox, written atomically, readable once the phone has been unlocked after
    /// a restart (a locked phone can still listen).
    static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sounds/levels.json")
    }

    static func standardStore(url: URL = AppLevels.standardURL) -> NoiseLevelsStoring {
        FileNoiseLevelsStore(url: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The patterns the shipped model was built with, staged into the bundle by `make core`.
    nonisolated static func bundledPatterns() throws -> String {
        guard let url = Bundle.main.url(forResource: "patterns", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw PatternCatalogue.Failure.unavailable("This build has no list of sounds to adjust. Run make core and rebuild.")
        }
        return text
    }

    private(set) var catalogue: PatternCatalogue?
    private(set) var unavailable: String?
    private(set) var levels: NoiseLevels = .fallback

    /// Rebuilds the detector from the current levels; set by the flow controller.
    var rebuild: () -> Void = { }
    /// Whether the detector is hearing the microphone now; set by the flow controller.
    var listening: () -> Bool = { false }

    private let models: ParrotModelStore
    private let store: NoiseLevelsStoring
    private let bundled: () throws -> String
    private var handler: LevelReadingHandler?

    init(models: ParrotModelStore, store: NoiseLevelsStoring = InMemoryNoiseLevelsStore(),
         bundled: @escaping () throws -> String = AppLevels.bundledPatterns) {
        self.models = models
        self.store = store
        self.bundled = bundled
        reload()
    }

    /// Reads the sounds of the active model and the saved levels again. A model change brings other sound names, so the levels are
    /// reconciled with them (names the model lost are dropped, names it gained start at their own level).
    func reload() {
        do {
            let found = try PatternCatalogue.load(store: models, bundled: bundled)
            catalogue = found
            unavailable = nil
            levels = (store.load() ?? NoiseLevels.defaults(for: found)).normalized(for: found)
        } catch {
            catalogue = nil
            unavailable = "\(error)"
            levels = store.load() ?? .fallback
        }
    }

    /// How to build the detector for `source`: its patterns with the saved levels written in, and the saved gain. Without a catalogue the
    /// model's own patterns are used as they always were, and the gain still applies.
    func setup(for source: ParrotModelStore.Source) -> Setup {
        reload()
        guard let catalogue, let rendered = try? catalogue.rendered(levels) else {
            return Setup(patternsJSON: source.patternsJSON, gain: levels.inputGain)
        }
        return Setup(patternsJSON: rendered, gain: levels.inputGain)
    }

    func makeModel() -> LevelsModel {
        reload()
        return LevelsModel(catalogue: catalogue, unavailable: unavailable, store: store, provider: self)
    }

    // MARK: SoundLevelsProvider

    var isListening: Bool { listening() }

    func startReadings(_ handler: @escaping LevelReadingHandler) { self.handler = handler }

    func stopReadings() { handler = nil }

    func apply(_ levels: NoiseLevels) {
        self.levels = levels
        rebuild()
    }

    /// A reading from the detector's listener, on the main queue.
    func receive(_ reading: LevelReading) { handler?(reading) }
}
