import Foundation

/// The UDP side of the pointer receiver. It opens one socket bound to ONE address (the tailnet address, or an address given with
/// `--bind`), never a wildcard, and only while the pointer service has a session; it closes it when the last session ends or the kill
/// switch is turned. It reads datagrams, hands each to the service and sends back what the service answers.
public final class UDPPointerTransport: PointerListener {
    public enum BindError: Error, Equatable {
        case wildcard
        case notAnIPv4Address
    }

    private let address: () -> String?
    private let port: UInt16
    private let logger: RequestLogger?
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var generation = 0
    private var bound: (address: String, port: UInt16)?
    public weak var service: PointerService?

    /// `address` is asked each time a socket is opened (the tailnet address changes), so it is never remembered. A wildcard address is
    /// refused outright: this socket must never listen on every interface.
    public init(address: @escaping () -> String?, port: UInt16, logger: RequestLogger? = nil) {
        self.address = address
        self.port = port
        self.logger = logger
    }

    /// Checks an address before it is bound.
    public static func validate(_ address: String) -> BindError? {
        var sin = in_addr()
        guard inet_pton(AF_INET, address, &sin) == 1 else { return .notAnIPv4Address }
        return sin.s_addr == 0 ? .wildcard : nil
    }

    public var endpoint: (address: String, port: UInt16)? {
        lock.lock(); defer { lock.unlock() }
        return bound
    }

    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return true }
        guard let host = address(), Self.validate(host) == nil else {
            logger?.log("assist pointer: no usable address to listen on; is Tailscale running?")
            return false
        }
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return false }
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &sin.sin_addr)
        // The reader of a socket stopped a moment ago closes it on its next 50 ms timeout; wait for that rather than fail.
        var ok = false
        for attempt in 0..<6 where !ok {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.03) }
            ok = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
            if !ok, errno != EADDRINUSE { break }
        }
        guard ok else {
            logger?.log("assist pointer: cannot bind udp \(host):\(port): errno \(errno)")
            close(socketFD)
            return false
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = socketFD
        generation += 1
        bound = (host, UInt16(bigEndian: actual.sin_port))
        logger?.log("assist pointer: listening on udp \(host):\(bound!.port)")
        let mine = generation
        Thread.detachNewThread { [weak self] in self?.run(socketFD, generation: mine) }
        return true
    }

    /// Does not wait for the reader: it notices on its next 50 ms timeout, and the socket is closed by whoever finds it stale.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        generation += 1
        let old = fd
        fd = -1
        bound = nil
        shutdown(old, SHUT_RDWR)
        logger?.log("assist pointer: udp socket closed")
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.generation == generation && fd >= 0
    }

    private func run(_ socketFD: Int32, generation: Int) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while isCurrent(generation) {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length) }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if count > 0, from.sin_family == sa_family_t(AF_INET) {
                var addr = from.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
                let source = String(cString: text)
                if let reply = service?.receive(Data(buffer[0..<count]), from: source, now: now) {
                    let bytes = [UInt8](reply)
                    withUnsafePointer(to: &from) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(socketFD, bytes, bytes.count, 0, $0, length) }
                    }
                }
            }
            service?.tick(now: now)
        }
        // Whoever replaced or stopped this socket left it to the reader to close.
        close(socketFD)
    }
}
