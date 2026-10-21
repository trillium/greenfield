import Foundation
import KitUI
import ParrotKit

/// What this app credits on the About screen, handed to the shared `AboutInfoView`: the speech model and its Core ML conversion
/// (CC BY 4.0), FluidAudio and what it contains (Apache-2.0 and others) and the shared package (MIT). `AttributionTests` fails when a
/// package the app ships has no entry here. The licence texts are bundled (`App/Sources/Licences`) so they read offline.
/// `docs/attribution.md` says why each is here.
enum AppCredits {
    static func licenceText(_ file: String, bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: file, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static let fluidAudioNotice = "FluidAudio is licensed under the Apache License, Version 2.0. This app uses it unmodified."

    private static let insideFluidAudioNotice = """
    FluidAudio lists the other projects it contains: fastcluster (BSD), text-processing-rs with NVIDIA NeMo Text Processing, \
    rustfst and flate2 (Apache-2.0 or MIT), VBx (Apache-2.0) and text frontends (Apache-2.0, MIT, BSD). Their notices are \
    reproduced in the licence text, as FluidAudio publishes them.
    """

    private static let parrotKitNotice = """
    ParrotKit is licensed under the MIT License; its copyright notice and permission notice are in the licence text.
    """

    static func credits(bundle: Bundle = .main) -> [AboutCredit] {
        let ccBy = licenceText("CC-BY-4.0", bundle: bundle)
        let fluidAudioURL = "https://github.com/FluidInference/FluidAudio"
        return [
            AboutCredit(id: "parakeet", name: ModelInfo.modelName, author: ModelInfo.modelCreator, licenceName: "CC BY 4.0",
                        role: "Speech recognition model, downloaded on first run", sourceURL: ModelInfo.modelSourceURL,
                        licenceURL: ModelInfo.modelLicenceURL, notice: ModelInfo.modelNotice, licenceText: ccBy),
            AboutCredit(id: "parakeet-coreml", name: "\(ModelInfo.modelName), Core ML conversion", author: ModelInfo.convertedBy,
                        licenceName: "CC BY 4.0", role: "The conversion of the model that runs on this phone",
                        sourceURL: ModelInfo.convertedURL, licenceURL: ModelInfo.modelLicenceURL,
                        notice: ModelInfo.conversionNotice, licenceText: ccBy),
            AboutCredit(id: "fluidaudio", name: "FluidAudio", author: "FluidInference", licenceName: "Apache License 2.0",
                        role: "Swift library that runs the model with Core ML", sourceURL: URL(string: fluidAudioURL),
                        licenceURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"), notice: fluidAudioNotice,
                        licenceText: licenceText("Apache-2.0-FluidAudio", bundle: bundle), packageIDs: ["fluidaudio"]),
            AboutCredit(id: "fluidaudio-third-party", name: "Components inside FluidAudio", author: "Their authors, named in the text",
                        licenceName: "BSD, MIT and Apache License 2.0, by component",
                        role: "Parts of FluidAudio that come from other projects",
                        sourceURL: URL(string: fluidAudioURL + "/tree/v0.17.7/ThirdPartyLicenses"), notice: insideFluidAudioNotice,
                        licenceText: licenceText("FluidAudio-ThirdParty", bundle: bundle)),
            AboutCredit(id: "parrotkit", name: "ParrotKit", author: "Trillium Smith", licenceName: "MIT License",
                        role: "Shared code: sound learning, health checks, setup and the Assist screens", notice: parrotKitNotice,
                        licenceText: licenceText("MIT-ParrotKit", bundle: bundle), packageIDs: ["parrotkit"]),
        ]
    }

    static let footnotes = [
        "This app's own code is released under the MIT License.",
        "NVIDIA, FluidInference and the other names above belong to their owners; they do not endorse this app.",
    ]

    /// The honesty lines for this app: the shared ones, plus what Teach and Assist send and where.
    static var strings: AboutStrings {
        var strings = AboutStrings()
        strings.onDeviceLines = [
            "The speech model runs on this phone, so your voice is not sent anywhere to be recognised. "
                + "It is downloaded once, the first time.",
            "The sounds the app listens for are matched on this phone. Sounds you record under Teach go only to your own trainer, "
                + "and only when you press Train.",
            "Text goes only to the computers you chose.",
            "The Assist tab sends pointer movements and window requests to the computer you chose, only while you use it.",
        ]
        return strings
    }

    static func info(bundle: Bundle = .main) -> AboutInfo {
        let build = BuildInfo(bundle: bundle)
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Greenfield"
        return AboutInfo(appName: name, appVersion: build.version, appBuild: build.build, kitVersion: ParrotKitInfo.version,
                         credits: credits(bundle: bundle), footnotes: footnotes)
    }
}
