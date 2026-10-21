import Foundation

/// What the attribution screen says about the speech model. The licence text of CC BY 4.0 asks for the creator, a notice of the licence,
/// a link, and a note of any change: all four are here, and `AppCredits` hands them to the shared About screen.
enum ModelInfo {
    static let modelName = "NVIDIA Parakeet TDT 0.6B v2"
    static let modelCreator = "NVIDIA Corporation"
    static let modelLicenceName = "Creative Commons Attribution 4.0 International (CC BY 4.0)"
    static let modelLicenceURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    static let modelSourceURL = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!
    static let convertedBy = "FluidInference"
    static let convertedURL = URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml")!

    /// Shown verbatim on the model's credit.
    static let modelNotice = """
    Speech is recognised on this phone with \(modelName), created by \(modelCreator) and licensed under \(modelLicenceName). \
    The model was converted to Core ML by \(convertedBy); that conversion is a change to the original. The model is downloaded \
    the first time the app runs and is not part of this app's code.
    """

    /// Shown verbatim on the conversion's credit.
    static let conversionNotice = """
    \(convertedBy) converted \(modelName), created by \(modelCreator), to Core ML. That conversion is a change to the original, made by \
    \(convertedBy), and is licensed under \(modelLicenceName) like the original. \(modelCreator) does not endorse this app or \
    the conversion.
    """
}
