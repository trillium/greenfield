import Foundation
import ParrotKit

/// This app's side of the shared model store (ParrotKit): where models live, what the shipped model is, and the one thing the kit cannot
/// know, how to prove a model runs here, by loading it in this app's detector exactly as listening does.
extension ParrotModelStore {
    static let appBundledName = "Bundled model"
    /// Pattern names of the shipped model's built-in set, for the rule editor.
    static let bundledPatterns = ["clap", "hiss", "kitty-cmere", "lip-pop", "piggy-oink", "shh", "tongue-click"]

    /// `Application Support/Sounds/Models`: the folder every earlier build used, so installed models carry over.
    static var appDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sounds/Models", isDirectory: true)
    }

    /// The injected check: build the detector from the candidate and report the sounds it really has.
    static let detectorValidator = ClosureModelValidator { model, patterns in
        do { return try SoundDetector(model: model, patternsJSON: patterns).labels } catch { throw Failure.coreRefused("\(error)") }
    }

    static func bundledModel() throws -> [UInt8] {
        guard let url = Bundle.main.url(forResource: "parrot-model", withExtension: "bin") else { throw Failure.noBundledModel }
        return [UInt8](try Data(contentsOf: url))
    }

    /// The store the app runs on.
    static func app(directory: URL = ParrotModelStore.appDirectory, validator: any ParrotModelValidator = detectorValidator,
                    bundled: @escaping @Sendable () throws -> [UInt8] = bundledModel) -> ParrotModelStore {
        ParrotModelStore(directory: directory, validator: validator, bundledName: appBundledName, bundledPatterns: bundledPatterns,
                         bundled: bundled)
    }
}
