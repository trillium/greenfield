import Foundation

/// What the attribution screen says about the speech model and the libraries around it. The licence text of CC BY 4.0 asks for the
/// creator, a notice of the licence, a link, and a note of any change: all four are here.
enum ModelInfo {
    struct Credit: Equatable, Identifiable {
        let name: String
        let role: String
        let licence: String
        let link: URL
        var id: String { name }
    }

    static let modelName = "NVIDIA Parakeet TDT 0.6B v2"
    static let modelCreator = "NVIDIA Corporation"
    static let modelLicenceName = "Creative Commons Attribution 4.0 International (CC BY 4.0)"
    static let modelLicenceURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    static let modelSourceURL = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!
    static let convertedBy = "FluidInference"
    static let convertedURL = URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml")!

    /// Shown verbatim on the attribution screen.
    static let modelNotice = """
    Speech is recognised on this phone with \(modelName), created by \(modelCreator) and licensed under \(modelLicenceName). \
    The model was converted to Core ML by \(convertedBy); that conversion is a change to the original. The model is downloaded \
    the first time the app runs and is not part of this app's code.
    """

    static let credits: [Credit] = [
        Credit(name: modelName, role: "Speech recognition model (downloaded on first run)", licence: "CC BY 4.0",
               link: modelLicenceURL),
        Credit(name: "FluidAudio", role: "Swift library that runs the model with Core ML", licence: "Apache License 2.0",
               link: URL(string: "https://github.com/FluidInference/FluidAudio")!)
    ]
}
