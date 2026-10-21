import Foundation

/// A spoken phrase that ends a dictation and submits it ("send it", "over and out"). Matched on the last words of the transcript only.
enum LineEnder {
    struct Match: Equatable {
        /// The phrase as configured.
        let phrase: String
        /// The transcript without the phrase (and without the comma or dash that led into it); may be empty.
        let remaining: String
    }

    /// The words of `text` (letters, digits, apostrophes) with where each starts, lower-cased for comparison.
    private static func words(in text: String) -> [(word: String, start: String.Index)] {
        var found: [(String, String.Index)] = []
        var current = ""
        var start: String.Index?
        for index in text.indices {
            let char = text[index]
            if char.isLetter || char.isNumber || char == "'" || char == "\u{2019}" {
                if start == nil { start = index }
                current.append(char)
            } else if let begun = start {
                found.append((current.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"), begun))
                current = ""
                start = nil
            }
        }
        if let begun = start { found.append((current.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"), begun)) }
        return found
    }

    /// The first configured phrase that is the last words of `transcript` (case-insensitive, trailing punctuation ignored). The phrase
    /// must be the end of what was said: it is never recognised in the middle of a sentence, and "send it to Dana" does not match.
    /// With several phrases the longest wins.
    static func match(_ transcript: String, phrases: [String]) -> Match? {
        let spoken = words(in: transcript)
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            let target = words(in: phrase).map(\.word)
            guard !target.isEmpty, spoken.count >= target.count else { continue }
            let tail = spoken.suffix(target.count)
            guard tail.map(\.word) == target, let first = tail.first else { continue }
            return Match(phrase: phrase, remaining: tidy(String(transcript[transcript.startIndex..<first.start])))
        }
        return nil
    }

    /// Drops the joiner left in front of the phrase ("everyone, " -> "everyone.") and the space.
    private static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = result.last else { return "" }
        if ",;:-\u{2013}\u{2014}".contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if let end = result.last, !".!?".contains(end) { result += "." }
        }
        return result
    }
}

/// The phrases, saved on the phone and editable in Sounds.
struct PhraseStore {
    struct Phrase: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var enabled = true
    }

    static let defaults = [Phrase(text: "send it"), Phrase(text: "over and out")]

    let defaults: UserDefaults
    private static let key = "spoken.lineEnders"

    func load() -> [Phrase] {
        guard let data = defaults.data(forKey: Self.key), let phrases = try? JSONDecoder().decode([Phrase].self, from: data) else {
            return Self.defaults
        }
        return phrases
    }

    func save(_ phrases: [Phrase]) {
        if let data = try? JSONEncoder().encode(phrases) { defaults.set(data, forKey: Self.key) }
    }
}
