import Foundation

/// Where the dictation flow is.
enum FlowState: String, Codable, CaseIterable, Sendable {
    /// Nothing happening.
    case idle
    /// The microphone is being recorded for dictation.
    case dictating
    /// Dictation ended; the text is in the text box, waiting to be sent.
    case review

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .dictating: return "Dictating"
        case .review: return "Review"
        }
    }
}

/// What a rule does when it fires.
enum FlowAction: String, Codable, CaseIterable, Sendable {
    case startDictation, endDictation, submit, clearText, none

    var title: String {
        switch self {
        case .startDictation: return "Start dictation"
        case .endDictation: return "End dictation, write text"
        case .submit: return "Submit text"
        case .clearText: return "Clear text"
        case .none: return "Nothing"
        }
    }
}

/// A sound, optionally repeated: `sound` heard `count` times within `withinSeconds`.
struct SoundTrigger: Codable, Equatable, Sendable {
    var sound: String
    var count = 1
    var withinSeconds = 1.5

    var summary: String { count > 1 ? "\(sound) × \(count)" : sound }
}

/// One editable rule: in `from`, when `trigger` is heard, go to `to` and do `action`.
struct SoundRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var trigger: SoundTrigger
    var from: FlowState
    var to: FlowState
    var action: FlowAction
    var enabled = true

    var summary: String { "\(trigger.summary): \(from.title) → \(to.title)" }

    /// The shipped defaults: kitty-cmere twice starts dictation (from idle, or again from review to add more text, which is
    /// appended to the end of the box), a tongue click ends dictation and writes the text, another tongue click submits it.
    static let defaults: [SoundRule] = [
        SoundRule(trigger: SoundTrigger(sound: "kitty-cmere", count: 2, withinSeconds: 1.5), from: .idle, to: .dictating,
                  action: .startDictation),
        SoundRule(trigger: SoundTrigger(sound: "kitty-cmere", count: 2, withinSeconds: 1.5), from: .review, to: .dictating,
                  action: .startDictation),
        SoundRule(trigger: SoundTrigger(sound: "tongue-click"), from: .dictating, to: .review, action: .endDictation),
        SoundRule(trigger: SoundTrigger(sound: "tongue-click"), from: .review, to: .idle, action: .submit)
    ]

    /// The first shipped default list, which had no review-state kitty-cmere rule. Saved copies of it are upgraded to the current one.
    static var firstDefaults: [SoundRule] {
        [defaults[0], defaults[2], defaults[3]]
    }
}

/// The rules plus the state they act on. Pure: feed it sounds, it says which rule fired.
struct RuleEngine: Equatable, Sendable {
    /// After a rule fires, the same sound is ignored for this long, so one click that the detector reports twice cannot fire two rules.
    static let settleSeconds = 0.5

    var rules: [SoundRule]
    private(set) var state: FlowState = .idle
    private var heard: [String: [Double]] = [:]
    private var settledUntil: [String: Double] = [:]

    init(rules: [SoundRule] = SoundRule.defaults, state: FlowState = .idle) {
        self.rules = rules
        self.state = state
    }

    /// Moves the state without a sound (the hold button, a finished submit). Forgets half-counted sounds.
    mutating func setState(_ next: FlowState) {
        state = next
        heard = [:]
    }

    /// A sound was heard at `time` (seconds on the detector's clock). Returns the rule that fired, if any.
    mutating func hear(_ sound: String, at time: Double) -> SoundRule? {
        if let until = settledUntil[sound], time < until { return nil }
        var recent = (heard[sound] ?? []).filter { time - $0 <= maxWindow(for: sound) && time >= $0 }
        recent.append(time)
        heard[sound] = recent
        guard let rule = rules.first(where: { matches($0, sound: sound, recent: recent, now: time) }) else { return nil }
        heard[sound] = []
        settledUntil[sound] = time + Self.settleSeconds
        state = rule.to
        return rule
    }

    private func maxWindow(for sound: String) -> Double {
        rules.filter { $0.trigger.sound == sound }.map(\.trigger.withinSeconds).max() ?? 0
    }

    private func matches(_ rule: SoundRule, sound: String, recent: [Double], now: Double) -> Bool {
        guard rule.enabled, rule.from == state, rule.trigger.sound == sound else { return false }
        return recent.filter { now - $0 <= rule.trigger.withinSeconds }.count >= max(rule.trigger.count, 1)
    }
}

/// Saves the rule list.
struct RuleStore {
    let defaults: UserDefaults
    private static let key = "sound.rules"

    func load() -> [SoundRule] {
        guard let data = defaults.data(forKey: Self.key), let rules = try? JSONDecoder().decode([SoundRule].self, from: data) else {
            return SoundRule.defaults
        }
        // A saved copy of the first defaults was never edited by the person (ids aside); give it the current defaults.
        let shape = { (list: [SoundRule]) in list.map { [$0.trigger.summary, $0.from.rawValue, $0.to.rawValue, $0.action.rawValue] } }
        return shape(rules) == shape(SoundRule.firstDefaults) ? SoundRule.defaults : rules
    }

    func save(_ rules: [SoundRule]) {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.key) }
    }
}
