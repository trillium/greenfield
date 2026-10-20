import Foundation

/// Pure helpers for the dictation benchmark: text normalisation, word error rate, percentiles, formatting checks.
enum SpikeMath {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                               "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// Spoken form of a non-negative integer below 10,000 ("45" -> "forty five"); larger values stay as digits.
    static func words(for number: Int) -> String {
        switch number {
        case ..<0: return String(number)
        case 0..<20: return ones[number]
        case 20..<100: return tens[number / 10] + (number % 10 == 0 ? "" : " " + ones[number % 10])
        case 100..<1000: return ones[number / 100] + " hundred" + (number % 100 == 0 ? "" : " " + words(for: number % 100))
        case 1000..<10_000: return ones[number / 1000] + " thousand" + (number % 1000 == 0 ? "" : " " + words(for: number % 1000))
        default: return String(number)
        }
    }

    /// Lower case, digits spelled out, punctuation removed (apostrophes kept), whitespace collapsed, split into words.
    static func normalize(_ text: String) -> [String] {
        var spelled = ""
        var digits = ""
        func flush() {
            if let value = Int(digits) { spelled += " " + words(for: value) + " " } else { spelled += digits }
            digits = ""
        }
        for char in text.lowercased() {
            if char.isASCII, char.isNumber { digits.append(char) } else {
                if !digits.isEmpty { flush() }
                spelled.append(char)
            }
        }
        if !digits.isEmpty { flush() }
        let cleaned = spelled.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "\u{2019}" { return Character(scalar) }
            return " "
        }
        return String(cleaned).replacingOccurrences(of: "\u{2019}", with: "'").split(separator: " ").map(String.init)
    }

    struct WordErrors: Equatable {
        var substitutions = 0, deletions = 0, insertions = 0, referenceWords = 0
        var errors: Int { substitutions + deletions + insertions }
        var rate: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

        static func + (lhs: WordErrors, rhs: WordErrors) -> WordErrors {
            WordErrors(substitutions: lhs.substitutions + rhs.substitutions, deletions: lhs.deletions + rhs.deletions,
                       insertions: lhs.insertions + rhs.insertions, referenceWords: lhs.referenceWords + rhs.referenceWords)
        }
    }

    /// Word-level edit distance between the normalised reference and hypothesis.
    static func wordErrors(reference: String, hypothesis: String) -> WordErrors {
        let ref = normalize(reference), hyp = normalize(hypothesis)
        var grid = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for row in 0...ref.count { grid[row][0] = row }
        for col in 0...hyp.count { grid[0][col] = col }
        if !ref.isEmpty, !hyp.isEmpty {
            for row in 1...ref.count {
                for col in 1...hyp.count {
                    let same = ref[row - 1] == hyp[col - 1]
                    grid[row][col] = min(grid[row - 1][col - 1] + (same ? 0 : 1), grid[row - 1][col] + 1, grid[row][col - 1] + 1)
                }
            }
        }
        var result = WordErrors(referenceWords: ref.count)
        var row = ref.count, col = hyp.count
        while row > 0 || col > 0 {
            if row > 0, col > 0, grid[row][col] == grid[row - 1][col - 1] + (ref[row - 1] == hyp[col - 1] ? 0 : 1) {
                if ref[row - 1] != hyp[col - 1] { result.substitutions += 1 }
                row -= 1; col -= 1
            } else if row > 0, grid[row][col] == grid[row - 1][col] + 1 {
                result.deletions += 1; row -= 1
            } else {
                result.insertions += 1; col -= 1
            }
        }
        return result
    }

    /// Nearest-rank percentile (0...100) of a list; 0 for an empty list.
    static func percentile(_ values: [Double], _ pct: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((pct / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// True when the text starts with a capital letter and ends with sentence punctuation: what dictation text needs.
    static func looksFormatted(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return false }
        return first.isUppercase && ".?!".contains(last)
    }
}

/// The fixed phrase set (`Spike/Phrases/phrases.json`).
struct SpikePhrases: Decodable {
    struct Phrase: Decodable, Equatable {
        let id: String
        let text: String
    }

    let phrases: [Phrase]
    let long: Phrase

    static func decode(_ data: Data) throws -> SpikePhrases {
        try JSONDecoder().decode(SpikePhrases.self, from: data)
    }
}
