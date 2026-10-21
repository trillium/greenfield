// Plain-language messages, one per line, so they read and edit as sentences.
// swiftlint:disable line_length
import Foundation
import KitHealth
import KitOnboarding

/// What the first-launch checklist and the "Am I ready?" line look at.
struct OnboardingInputs {
    var microphone: HealthInputs.Permission = .undetermined
    var localNetwork: LocalNetworkState = .unknown
    var tailnetConnected = false
    var speechModel: DictationSession.ModelState = .notLoaded
    var detectorListening = false
    var detectorProblem: String?
    /// Computers that answered and are compatible, and whether one is chosen.
    var readyComputers = 0
    var computers = 0
    var hasChosenComputer = false
}

enum LocalNetworkState: Equatable {
    case unknown, granted, denied
}

/// What the buttons of this app's checklist do: the names ParrotKit does not already have (the app maps each to an action in `perform`).
extension OnboardingFix {
    static let allowLocalNetwork: OnboardingFix = "allowLocalNetwork"
    static let openTailscale: OnboardingFix = "openTailscale"
    static let downloadModel: OnboardingFix = "downloadModel"
    static let restartDetector: OnboardingFix = "restartDetector"
}

/// This app's steps, handed to the shared onboarding framework (KitOnboarding): the checklist, the "Am I ready?" line and the
/// first-launch memory are the kit's. Pure: the screen gathers the facts, this words them.
enum AppOnboarding {
    static let strings: OnboardingStrings = {
        var strings = OnboardingStrings()
        strings.ready = "Ready. Say kitty-cmere twice, or tap the microphone."
        return strings
    }()

    static func onboarding(_ input: OnboardingInputs) -> Onboarding {
        Onboarding(checks: [
            ClosureOnboardingCheck(id: "microphone") { microphone(input) },
            ClosureOnboardingCheck(id: "localnetwork") { localNetwork(input) },
            ClosureOnboardingCheck(id: "tailscale") { tailscale(input) },
            ClosureOnboardingCheck(id: "speech") { speech(input) },
            ClosureOnboardingCheck(id: "detector") { detector(input) },
            ClosureOnboardingCheck(id: "computer") { computer(input) }
        ], strings: strings)
    }

    static func checklist(_ input: OnboardingInputs) -> [OnboardingItem] { onboarding(input).checklist() }

    private static func microphone(_ input: OnboardingInputs) -> OnboardingItem {
        switch input.microphone {
        case .granted:
            return item("microphone", "Microphone", .done, "Allowed.")
        case .denied:
            return item("microphone", "Microphone", .blocked, "Microphone access is off, so nothing can be heard.", .openSettings, "Open Settings and turn the microphone on")
        case .undetermined:
            return item("microphone", "Microphone", .todo, "Greenfield listens on this phone. What you dictate is never sent as audio.", .allowMicrophone, "Allow the microphone")
        }
    }

    private static func localNetwork(_ input: OnboardingInputs) -> OnboardingItem {
        switch input.localNetwork {
        case .granted:
            return item("localnetwork", "Local network", .done, "Allowed.")
        case .denied:
            return item("localnetwork", "Local network", .blocked, "Local network access is off, so nearby computers cannot be found.", .openSettings, "Open Settings and turn Local Network on")
        case .unknown:
            return item("localnetwork", "Local network", .todo, "Lets the phone find your computers.", .allowLocalNetwork, "Allow the local network")
        }
    }

    private static func tailscale(_ input: OnboardingInputs) -> OnboardingItem {
        input.tailnetConnected
            ? item("tailscale", "Tailscale", .done, "This phone is on your tailnet.")
            : item("tailscale", "Tailscale", .todo, "Greenfield reaches your computers through Tailscale, and it is off on this phone.", .openTailscale, "Open Tailscale and turn it on")
    }

    private static func speech(_ input: OnboardingInputs) -> OnboardingItem {
        switch input.speechModel {
        case .ready:
            return item("speech", "Speech model", .done, "Downloaded and loaded.")
        case .downloading(let fraction):
            return item("speech", "Speech model", .working(fraction), "Downloading, \(Int((fraction * 100).rounded()))%. One time, about 0.5 GB. Keep the app open.")
        case .loading:
            return item("speech", "Speech model", .working(nil), "On this phone, loading (about 15 seconds).")
        case .failed(let message):
            return item("speech", "Speech model", .blocked, "It could not load: \(message)", .downloadModel, "Try the download again")
        case .notLoaded:
            return item("speech", "Speech model", .todo, "Needed once, about 0.5 GB.", .downloadModel, "Download the speech model")
        }
    }

    private static func detector(_ input: OnboardingInputs) -> OnboardingItem {
        if let problem = input.detectorProblem {
            return item("detector", "Sound detector", .blocked, "It could not start: \(problem)", .restartDetector, "Start the sound detector again")
        }
        return input.detectorListening
            ? item("detector", "Sound detector", .done, "Listening for kitty-cmere and tongue clicks.")
            : item("detector", "Sound detector", .todo, "Not listening yet.", .restartDetector, "Start the sound detector")
    }

    private static func computer(_ input: OnboardingInputs) -> OnboardingItem {
        if input.hasChosenComputer && input.readyComputers > 0 {
            return item("computer", "Your computer", .done, input.readyComputers == 1 ? "Found and ready." : "\(input.readyComputers) computers found and ready.")
        }
        if input.computers == 0 {
            return item("computer", "Your computer", .todo, "No computer is set up. Greenfield looks on your tailnet and network by itself, or scan the code the installer shows.",
                        .findComputers, "Look for computers")
        }
        return item("computer", "Your computer", .todo, "Computers are set up, but none is ready and chosen yet.", .findComputers, "Check the computers again")
    }

    private static func item(_ id: String, _ title: String, _ state: OnboardingItem.State, _ detail: String, _ fix: OnboardingFix? = nil,
                             _ label: String? = nil) -> OnboardingItem {
        OnboardingItem(id: id, title: title, state: state, detail: detail, fix: fix, fixLabel: label)
    }
}
// swiftlint:enable line_length
