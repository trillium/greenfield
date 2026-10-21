import Foundation
import CryptoKit
import KitAssist

/// The tag on every datagram of a pointer session: the first 16 bytes of HMAC-SHA256 over the whole datagram before the tag (header and
/// payload), keyed with the 32-byte key the daemon returned when the session was opened over the authenticated HTTP route. The same key
/// and rule are used for the daemon's replies. The comparison takes the same time whether the tag is right or wrong.
///
/// Known answer (also in `docs/assist-pointer.md`, so the phone can check its own): key = 32 bytes `00 01 02 ... 1f`, datagram = the
/// 18-byte header of a BYE `54505431 05 00 01020304 00000001 00000000` gives the tag `97b9dada3fe4445daeb8aee2ce65ff2d`.
public struct PointerAuthenticator: TPT1Authenticator {
    public static let tagBytes = 16
    public static let keyBytes = 32

    private let key: SymmetricKey

    public init(key: Data) { self.key = SymmetricKey(data: key) }

    public var tagLength: Int { Self.tagBytes }

    public func tag(for body: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: body, using: key).prefix(Self.tagBytes))
    }

    public func isValid(tag: Data, for body: Data) -> Bool {
        let expected = self.tag(for: body)
        guard tag.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(tag, expected) { difference |= a ^ b }
        return difference == 0
    }
}
