// Plain-language messages, one per line, so they read and edit as sentences.
// swiftlint:disable line_length
import Foundation

/// A plain-words check of everything the app depends on, each failure with the fix. Pure: the screen gathers the facts, this decides.
struct HealthItem: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case ok, warning, problem
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let title: String
    let level: Level
    let detail: String
    /// What to do about it; nil when nothing is wrong.
    let fix: String?
}

struct HealthInputs {
    enum Permission { case granted, denied, undetermined }

    struct Computer {
        let name: String
        let address: String
        let isActive: Bool
        let hasKey: Bool
        /// nil when it has not been checked yet (or has no key to check with).
        let answer: ReceiverClient.Health?
    }

    var speechModel: DictationSession.ModelState = .notLoaded
    var speechModelOnDisk = false
    var microphonePermission: Permission = .undetermined
    var microphoneStatus: ListenMachine.Status = .off
    var audioFlowing = false
    var detectorModel = ""
    var detectorProblem: String?
    var detectorListening = false
    var tailnetConnected = true
    var computers: [Computer] = []
    var queued = 0
    /// This app's own version and the oldest agent it works with (nil in tests that do not care).
    var appVersion: Semver?
    var minimumAgent: Semver?
}

enum HealthReport {
    static func build(_ input: HealthInputs) -> [HealthItem] {
        [speech(input), permission(input), microphone(input), detector(input), tailnet(input)]
            + computers(input) + [outbox(input)]
    }

    static func summary(_ items: [HealthItem]) -> String {
        let problems = items.filter { $0.level == .problem }.count
        let warnings = items.filter { $0.level == .warning }.count
        if problems > 0 { return problems == 1 ? "1 thing needs fixing" : "\(problems) things need fixing" }
        if warnings > 0 { return warnings == 1 ? "Working, 1 thing to look at" : "Working, \(warnings) things to look at" }
        return "Everything is working"
    }

    private static func speech(_ input: HealthInputs) -> HealthItem {
        let title = "Speech model (Parakeet)"
        switch input.speechModel {
        case .ready:
            return HealthItem(id: "speech", title: title, level: .ok, detail: "Present on this phone and loaded.", fix: nil)
        case .loading:
            return HealthItem(id: "speech", title: title, level: .warning, detail: "On this phone, loading. This takes about 15 s after an update.",
                              fix: "Wait a moment; nothing to do.")
        case .downloading(let fraction):
            return HealthItem(id: "speech", title: title, level: .warning,
                              detail: "Downloading, \(Int((fraction * 100).rounded()))%. One time only, about 0.5 GB.",
                              fix: "Keep the app open and the phone online until it finishes.")
        case .failed(let message):
            return HealthItem(id: "speech", title: title, level: .problem, detail: "The model could not load: \(message)",
                              fix: input.speechModelOnDisk
                                ? "Close and reopen the app. If it keeps failing, delete the app and install it again."
                                : "Connect the phone to the internet, then close and reopen the app to download it.")
        case .notLoaded:
            return HealthItem(id: "speech", title: title, level: .warning, detail: "Not started yet.", fix: "Open the Dictate screen.")
        }
    }

    private static func permission(_ input: HealthInputs) -> HealthItem {
        let title = "Microphone permission"
        switch input.microphonePermission {
        case .granted: return HealthItem(id: "permission", title: title, level: .ok, detail: "Allowed.", fix: nil)
        case .denied:
            return HealthItem(id: "permission", title: title, level: .problem, detail: "Microphone access is off, so nothing can be heard.",
                              fix: "Open iPhone Settings > Greenfield and turn Microphone on.")
        case .undetermined:
            return HealthItem(id: "permission", title: title, level: .warning, detail: "Not asked yet.",
                              fix: "Reopen the app and tap Allow when iOS asks.")
        }
    }

    private static func microphone(_ input: HealthInputs) -> HealthItem {
        let title = "Microphone listening"
        switch input.microphoneStatus {
        case .listening, .backgrounded:
            return input.audioFlowing
                ? HealthItem(id: "mic", title: title, level: .ok, detail: "Audio is arriving.", fix: nil)
                : HealthItem(id: "mic", title: title, level: .warning, detail: "The microphone is on but no audio arrived in the last 2 s.",
                             fix: "Say something; if this stays, tap \"Try the microphone again\" on the Dictate screen.")
        case .interrupted(let reason), .gaveUp(let reason):
            return HealthItem(id: "mic", title: title, level: .problem, detail: "The microphone stopped: \(reason).",
                              fix: "Finish the call or other audio, then tap \"Try the microphone again\" on the Dictate screen.")
        case .off:
            let denied = input.microphonePermission == .denied
            return HealthItem(id: "mic", title: title, level: denied ? .problem : .warning, detail: "The microphone is off.",
                              fix: denied ? "Allow the microphone in iPhone Settings > Greenfield." : "Open the Dictate screen; it starts when the app is open.")
        }
    }

    private static func detector(_ input: HealthInputs) -> HealthItem {
        let title = "Sound detector (Parrot)"
        if let problem = input.detectorProblem {
            return HealthItem(id: "detector", title: title, level: .problem, detail: "The sound model could not load: \(problem)",
                              fix: "In Sounds > Model packs choose the bundled model; if that fails, reinstall the app.")
        }
        guard !input.detectorModel.isEmpty else {
            return HealthItem(id: "detector", title: title, level: .warning, detail: "Not started yet.", fix: "Open the Dictate screen.")
        }
        guard input.detectorListening else {
            return HealthItem(id: "detector", title: title, level: .problem, detail: "\(input.detectorModel) is loaded but not listening.",
                              fix: "Close and reopen the app.")
        }
        return HealthItem(id: "detector", title: title, level: .ok,
                          detail: "\(input.detectorModel) loaded and listening on the microphone, in every state.", fix: nil)
    }

    private static func tailnet(_ input: HealthInputs) -> HealthItem {
        let title = "Tailnet"
        let needed = input.computers.contains { Tailnet.needsTailnet(host(of: $0.address)) }
        if input.tailnetConnected {
            return HealthItem(id: "tailnet", title: title, level: .ok, detail: "This phone is connected to the tailnet.", fix: nil)
        }
        return HealthItem(id: "tailnet", title: title, level: needed ? .problem : .warning,
                          detail: "This phone is not connected to a tailnet, so tailnet names and 100.x addresses cannot be reached.",
                          fix: "Open Tailscale on this phone and turn it on.")
    }

    private static func computers(_ input: HealthInputs) -> [HealthItem] {
        guard !input.computers.isEmpty else {
            return [HealthItem(id: "computers", title: "Computers", level: .problem, detail: "No computer is set up, so there is nowhere to send text.",
                               fix: "Add one in the Computers tab: its tailnet name and its key.")]
        }
        var items = input.computers.map { computer($0, app: input.appVersion, minimumAgent: input.minimumAgent) }
        if !input.computers.contains(where: \.isActive) {
            items.append(HealthItem(id: "active", title: "Active computer", level: .problem, detail: "No computer is chosen to receive text.",
                                    fix: "Tap a computer in the Computers tab to make it the active one."))
        }
        return items
    }

    static func computer(_ computer: HealthInputs.Computer, app: Semver? = nil, minimumAgent: Semver? = nil) -> HealthItem {
        let title = computer.name + (computer.isActive ? " (active)" : "")
        let id = "computer-" + computer.name
        let agent = "greenfield-inserter"
        guard let answer = computer.answer else {
            return HealthItem(id: id, title: title, level: .warning, detail: "Not checked yet.", fix: "Tap Check again.")
        }
        switch answer {
        case .ready(let status):
            return ready(status, of: computer, id: id, title: title, versions: (app, minimumAgent))
        case .wrongKey where computer.hasKey:
            return HealthItem(id: id, title: title, level: .problem, detail: "The computer is reachable but refuses the key saved for it.",
                              fix: "Open the computer under Computers > Advanced and remove the saved key (computers on the tailnet need none), or enter the right one.")
        case .wrongKey:
            return HealthItem(id: id, title: title, level: .problem, detail: "The computer is reachable but its input agent asks for a key.",
                              fix: "Update the agent on \(computer.name) (`\(agent)`) to the version that trusts the tailnet, or add its key under Computers > Advanced.")
        case .keyNotSetOnMac:
            return HealthItem(id: id, title: title, level: .problem, detail: "The computer is reachable but its input agent is not set up yet.",
                              fix: "On \(computer.name) update and restart the agent (`\(agent) health` says what is missing).")
        case .incompatible(let message):
            return HealthItem(id: id, title: title, level: .problem, detail: message, fix: "Update the app or the agent so their versions match.")
        case .unreachable(let reason):
            return HealthItem(id: id, title: title, level: .problem, detail: reason,
                              fix: "Check that Tailscale is on here and on \(computer.name), that the computer is awake, and that its agent is running (`\(agent) key status`).")
        }
    }

    private static func ready(_ status: ReceiverClient.MacStatus, of computer: HealthInputs.Computer, id: String, title: String,
                              versions: (app: Semver?, minimumAgent: Semver?)) -> HealthItem {
        let (app, minimumAgent, name) = (versions.app, versions.minimumAgent, computer.name)
        let agent = status.version.isEmpty ? "" : " (agent \(status.version))"
        let appText = app.map { "\($0)" } ?? "unknown"
        let verdict = Compatibility.judge(app: app, agent: status.version, minClient: status.minClientVersion, minimumAgent: minimumAgent)
        switch verdict {
        case .updateAgent:
            return HealthItem(id: id, title: title, level: .problem,
                              detail: "Update the Mac daemon: it is \(status.version.isEmpty ? "too old to state a version" : "version \(status.version)"), and this app (\(appText)) needs \(minimumAgent.map { "\($0) or newer" } ?? "a newer one") on the same line.",
                              fix: "On \(name) install the current greenfield-inserter (`make -C mac install`), then Check again.")
        case .updateApp:
            return HealthItem(id: id, title: title, level: .problem,
                              detail: "Update the app: this app is \(appText) and that computer's agent (\(status.version)) needs \(status.minClientVersion.map { "\($0) or newer" } ?? "a newer app").",
                              fix: "Install the newest Greenfield on this phone, then Check again.")
        case .compatible: break
        }
        if let view = status.appCompatibility, !view.works {
            return HealthItem(id: id, title: title, level: .warning, detail: "Reachable\(agent). The computer reports: \(view.message)",
                              fix: view.fix ?? "Update whichever of the app and the agent is older.")
        }
        if !status.accessibility {
            return HealthItem(id: id, title: title, level: .problem, detail: "Reachable\(agent), but it cannot type yet: Accessibility is not approved.",
                              fix: "On \(name): System Settings > Privacy & Security > Accessibility, switch on greenfield-inserter.")
        }
        if status.locked {
            return HealthItem(id: id, title: title, level: .warning, detail: "Reachable\(agent), but its screen is locked, so text would wait.",
                              fix: "Unlock \(name); the text arrives when you retry.")
        }
        if status.secureInput {
            return HealthItem(id: id, title: title, level: .warning, detail: "Reachable\(agent), but a password field is focused there.",
                              fix: "Click out of the password field on \(name), then retry.")
        }
        if let line = status.delivery, !line.works {
            return HealthItem(id: id, title: title, level: .problem, detail: "Reachable\(agent), but it cannot actually insert text: \(line.message)",
                              fix: line.fix ?? "On \(name) run `greenfield-inserter doctor`; it says what is missing.")
        }
        let delivery = status.delivery.map { " \($0.message)." } ?? ""
        return HealthItem(id: id, title: title, level: .ok,
                          detail: "Compatible (app \(appText)). Ready\(agent);\(delivery) \(status.insertedCount) texts inserted so far.", fix: nil)
    }

    private static func outbox(_ input: HealthInputs) -> HealthItem {
        if input.queued == 0 { return HealthItem(id: "outbox", title: "Outbox", level: .ok, detail: "Nothing is waiting.", fix: nil) }
        return HealthItem(id: "outbox", title: "Outbox", level: .warning,
                          detail: input.queued == 1 ? "1 text is waiting to be sent." : "\(input.queued) texts are waiting to be sent.",
                          fix: "Fix the computer above, then open the Outbox and tap Retry.")
    }

    private static func host(of address: String) -> String {
        String(address.split(separator: ":", maxSplits: 1).first ?? "")
    }
}
// swiftlint:enable line_length
