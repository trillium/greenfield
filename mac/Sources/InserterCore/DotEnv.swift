import Foundation

/// Reads the repository's `.env` and turns it into the port the daemon uses, so no port number is
/// written in code. The file is only parsed, never executed.
public enum DotEnv {
    public static let portVariable = "GREENFIELD_PORT"

    /// KEY=VALUE lines; blank lines and `#` comments are skipped, `export ` and one pair of quotes are removed.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  !(key.first?.isNumber ?? false) else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// The nearest `.env` at or above `directory`.
    public static func find(from directory: URL, fileManager: FileManager = .default) -> URL? {
        var dir = directory.standardizedFileURL
        while true {
            let candidate = dir.appendingPathComponent(".env")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    public static func load(from directory: URL) -> [String: String] {
        guard let file = find(from: directory), let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// The port to use: `--port` wins, then the environment, then `.env`. With none of them, `InserterDefaults.port`, so a fresh checkout works without a `.env`.
    public static func port(flag: String?, environment: [String: String], dotEnv: [String: String]) -> Result<UInt16, PortError> {
        let source = flag ?? nonEmpty(environment[portVariable]) ?? nonEmpty(dotEnv[portVariable])
        guard let text = source else { return .success(UInt16(InserterDefaults.port)) }
        guard let n = UInt16(text), n != 0 else { return .failure(.invalid(text)) }
        return .success(n)
    }

    private static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
}

public enum PortError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let s): return "bad port '\(s)': expected a number from 1 to 65535"
        }
    }
}
