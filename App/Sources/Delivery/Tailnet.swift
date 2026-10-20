import Darwin
import Foundation

/// Knows what a tailnet address looks like and whether this phone is on the tailnet right now.
enum Tailnet {
    static let notConnectedMessage = "This phone is not connected to your tailnet. Turn on Tailscale, then try again."

    /// A dotted IPv4 literal such as `100.84.99.99`.
    static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// 100.64.0.0/10, the range Tailscale assigns.
    static func isTailnetAddress(_ host: String) -> Bool {
        guard isIPv4Literal(host), let first = host.split(separator: ".").first.flatMap({ Int($0) }),
              let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    /// A name or address that only exists inside the tailnet: a `*.ts.net` name or a 100.x address.
    static func needsTailnet(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".ts.net") || isTailnetAddress(host)
    }

    /// True when an interface of this phone has a 100.64.0.0/10 address (the tailnet's virtual interface is up).
    static func isConnected() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if value >> 22 == 0x191 { return true }  // 100.64.0.0/10: top 10 bits 0110 0100 01
        }
        return false
    }
}
