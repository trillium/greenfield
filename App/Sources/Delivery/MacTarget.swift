import Foundation

/// One Mac the phone can send text to. The secret key is not part of this value: it lives in the Keychain under `id`.
struct MacTarget: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// A tailnet name (`macbook.example.ts.net`), a tailnet or LAN address, or `host:port`.
    var address: String

    /// The port the Mac input agent listens on.
    static let defaultPort = 47821

    init(id: UUID = UUID(), name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }

    /// `http://host:port`, or nil when the address is empty or malformed. A bare host gets the default port.
    var baseURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" ") else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch pieces.count {
        case 1:
            parts.host = trimmed
            parts.port = Self.defaultPort
        case 2:
            guard let port = Int(pieces[1]), (1...65_535).contains(port), !pieces[0].isEmpty else { return nil }
            parts.host = String(pieces[0])
            parts.port = port
        default:
            return nil
        }
        return parts.url
    }

    var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && baseURL != nil }
}
