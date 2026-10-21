import CryptoKit
import Foundation

/// One file carrying a trained sound model and what the app needs to use it.
///
///     8 bytes   magic "PARROTPK"
///     4 bytes   manifest length (big-endian), then the manifest: UTF-8 JSON
///     4 bytes   patterns length, then the patterns JSON: pattern name -> {"sounds": [labels], threshold, throttle}
///     8 bytes   model length, then the model itself (a PRRTMLP1 file)
///     32 bytes  SHA-256 of every byte before this trailer
///
/// Parsing is all-or-nothing: any problem throws and no partial pack is returned.
struct ParrotModelPack: Equatable {
    struct Manifest: Codable, Equatable {
        let format: Int
        let name: String
        let labels: [String]
        let trainedWith: String?
        let created: String?
        let modelSha256: String

        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey {
            case format, name, labels, created
            case trainedWith = "trained_with"
            case modelSha256 = "model_sha256"
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAPack, damaged, notAModel
        case badLength(String)
        case unsupportedFormat(Int)
        case manifestMismatch(String)
        case badLabels(String)
        case badPatterns(String)

        var description: String {
            switch self {
            case .notAPack: return "That file is not a sound model pack."
            case .damaged: return "The model pack is damaged or was changed (its checksum does not match)."
            case .notAModel: return "The model inside the pack is not a sound model."
            case .badLength(let what): return "The model pack's \(what) has an impossible length."
            case .unsupportedFormat(let version): return "This model pack uses format \(version), which this app does not know."
            case .manifestMismatch(let why): return "The model pack contradicts itself: \(why)."
            case .badLabels(let why): return "The model pack's sounds are not usable: \(why)."
            case .badPatterns(let why): return "The model pack's patterns are not usable: \(why)."
            }
        }
    }

    static let magic = Array("PARROTPK".utf8)
    static let modelMagic = Array("PRRTMLP1".utf8)
    static let format = 1
    static let maxManifest = 64 * 1024
    static let maxPatterns = 256 * 1024
    static let maxModel = 200 * 1024 * 1024
    /// Classes that mean "not a command"; a model needs one to tell a sound from nothing.
    static let baselinePrefixes = ["background_noise", "silence"]

    let manifest: Manifest
    let patternsJSON: String
    let model: [UInt8]

    /// Pattern names in the pack, sorted (what rules can refer to).
    var patternNames: [String] { Self.patternNames(in: patternsJSON) }

    static func isBaseline(_ label: String) -> Bool { baselinePrefixes.contains { label.hasPrefix($0) } }

    static func patternNames(in json: String) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [] }
        return root.keys.sorted()
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.magic.count + 4 + 4 + 8 + 32, Array(bytes.prefix(Self.magic.count)) == Self.magic else {
            throw Failure.notAPack
        }
        let body = bytes.count - 32
        guard Data(SHA256.hash(data: bytes[0..<body])) == Data(bytes[body...]) else { throw Failure.damaged }
        var reader = Reader(bytes: bytes, end: body, position: Self.magic.count)
        let manifestBytes = try reader.chunk(prefix: 4, limit: Self.maxManifest, "manifest")
        let patternBytes = try reader.chunk(prefix: 4, limit: Self.maxPatterns, "patterns")
        let modelBytes = try reader.chunk(prefix: 8, limit: Self.maxModel, "model")
        guard reader.position == body else { throw Failure.badLength("body (trailing data)") }

        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(manifestBytes)) else {
            throw Failure.manifestMismatch("the manifest cannot be read")
        }
        guard manifest.format == Self.format else { throw Failure.unsupportedFormat(manifest.format) }
        guard Array(modelBytes.prefix(Self.modelMagic.count)) == Self.modelMagic else { throw Failure.notAModel }
        guard Self.sha256Hex(modelBytes) == manifest.modelSha256 else {
            throw Failure.manifestMismatch("the model does not match its checksum in the manifest")
        }
        guard let patterns = String(data: Data(patternBytes), encoding: .utf8) else { throw Failure.badPatterns("not text") }
        try Self.checkLabels(manifest.labels)
        try Self.checkPatterns(patterns, labels: manifest.labels)
        self.manifest = manifest
        patternsJSON = patterns
        model = Array(modelBytes)
    }

    /// Builds a pack (tests, and anything on the phone that packages a model).
    static func encode(model: [UInt8], labels: [String], name: String, patternsJSON: String, created: String? = nil) throws -> Data {
        guard Array(model.prefix(modelMagic.count)) == modelMagic else { throw Failure.notAModel }
        try checkLabels(labels)
        try checkPatterns(patternsJSON, labels: labels)
        let manifest = Manifest(format: format, name: name, labels: labels, trainedWith: nil, created: created,
                                modelSha256: sha256Hex(model))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = [UInt8](try encoder.encode(manifest))
        let patternBytes = [UInt8](patternsJSON.utf8)
        var out = magic + big(manifestBytes.count, 4) + manifestBytes + big(patternBytes.count, 4) + patternBytes
        out += big(model.count, 8) + model
        out += Array(SHA256.hash(data: out))
        return Data(out)
    }

    private struct Reader {
        let bytes: [UInt8]
        let end: Int
        var position: Int

        mutating func chunk(prefix: Int, limit: Int, _ what: String) throws -> ArraySlice<UInt8> {
            guard position + prefix <= end else { throw Failure.badLength(what) }
            var length: UInt64 = 0
            for byte in bytes[position..<(position + prefix)] { length = (length << 8) | UInt64(byte) }
            position += prefix
            guard length <= UInt64(limit), position + Int(length) <= end else { throw Failure.badLength(what) }
            defer { position += Int(length) }
            return bytes[position..<(position + Int(length))]
        }
    }

    private static func big(_ value: Int, _ width: Int) -> [UInt8] {
        (0..<width).map { UInt8((UInt64(value) >> UInt64(8 * (width - 1 - $0))) & 0xFF) }
    }

    private static func sha256Hex<Bytes: DataProtocol>(_ bytes: Bytes) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkLabels(_ labels: [String]) throws {
        guard labels.count >= 2, Set(labels).count == labels.count else { throw Failure.badLabels("need at least two different sounds") }
        guard labels.contains(where: isBaseline) else {
            throw Failure.badLabels("no background_noise or silence class to tell a sound from nothing")
        }
    }

    private static func checkPatterns(_ json: String, labels: [String]) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], !root.isEmpty else {
            throw Failure.badPatterns("not a JSON object of patterns")
        }
        for (name, body) in root {
            guard let sounds = (body as? [String: Any])?["sounds"] as? [String], !sounds.isEmpty else {
                throw Failure.badPatterns("\(name) has no sounds")
            }
            if let unknown = sounds.first(where: { !labels.contains($0) }) {
                throw Failure.badPatterns("\(name) uses \(unknown), which the model does not have")
            }
        }
    }
}
