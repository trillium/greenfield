import Foundation

/// Finds this Mac's tailnet address: an IPv4 address in the CGNAT range 100.64.0.0/10
/// that Tailscale assigns. Binding only to it keeps the daemon off LAN and loopback.
public enum Tailnet {
    public static func ipv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let host = UInt32(bigEndian: sin.sin_addr.s_addr)
            if host & 0xFFC0_0000 == 0x6440_0000 {    // 100.64.0.0/10
                var a = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
                return String(cString: buf)
            }
        }
        return nil
    }
}

/// A small blocking HTTP/1.1 server on BSD sockets, one short-lived connection per request.
public final class HTTPServer {
    public enum BindTarget {
        /// The tailnet address plus loopback.
        case tailnet
        case address(String)
    }

    private let target: BindTarget
    private let port: UInt16
    private let handler: RequestHandler
    private let logger: RequestLogger?
    private let queue = DispatchQueue(label: "inserter.connections", attributes: .concurrent)

    public init(target: BindTarget, port: UInt16, handler: RequestHandler, logger: RequestLogger?) {
        self.target = target
        self.port = port
        self.handler = handler
        self.logger = logger
    }

    /// Addresses currently being served, as "ip:port"; reported by /status.
    public func listening() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return active.sorted()
    }

    private let lock = NSLock()
    private var active = Set<String>()

    private func setActive(_ address: String, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { active.insert("\(address):\(port)") } else { active.remove("\(address):\(port)") }
    }

    /// Runs forever. By default serves on the tailnet address and on loopback, nothing else; an
    /// explicit address replaces both. Each listener waits for its address and re-binds if it goes away.
    public func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        switch target {
        case .address(let a):
            thread { self.runListener(fixed: a) }
        case .tailnet:
            thread { self.runListener(fixed: "127.0.0.1") }
            thread { self.runListener(fixed: nil) }
        }
        while true { sleep(3600) }
    }

    private func thread(_ body: @escaping () -> Void) {
        Thread.detachNewThread(body)
    }

    /// `fixed` nil means "whatever the tailnet address currently is".
    private func runListener(fixed: String?) {
        var waitingLogged = false
        while true {
            let address: String
            if let fixed = fixed {
                address = fixed
            } else {
                guard let a = Tailnet.ipv4() else {
                    if !waitingLogged { logger?.log("no tailnet address yet; waiting for Tailscale"); waitingLogged = true }
                    sleep(5)
                    continue
                }
                address = a
            }
            waitingLogged = false
            guard let fd = listen(on: address) else { sleep(5); continue }
            logger?.log("listening on \(address):\(port)")
            setActive(address, true)
            serve(fd, address: address, followTailnet: fixed == nil)
            setActive(address, false)
            close(fd)
            logger?.log("listener on \(address) stopped; rebinding")
        }
    }

    private func listen(on address: String) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { close(fd); return nil }
        let bound = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            logger?.log("cannot listen on \(address):\(port): errno \(errno)")
            close(fd)
            return nil
        }
        return fd
    }

    private func serve(_ listener: Int32, address: String, followTailnet: Bool) {
        // Accept with a timeout so we can notice the tailnet address disappearing.
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                queue.async { self.handle(client) }
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if followTailnet, Tailnet.ipv4() != address { return }
                continue
            }
            return
        }
    }

    private func peerAddress(_ fd: Int32) -> String? {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) == 0 }
        }
        guard ok, addr.sin_family == sa_family_t(AF_INET) else { return nil }
        var a = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    private func isLoopbackPeer(_ fd: Int32) -> Bool {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) == 0 }
        }
        return ok && addr.sin_family == sa_family_t(AF_INET) && UInt32(bigEndian: addr.sin_addr.s_addr) >> 24 == 127
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var response: HTTPResponse?
        while response == nil {
            switch HTTPParser.parse(buffer) {
            case .complete(var request):
                request.fromLoopback = isLoopbackPeer(fd)
                request.peerAddress = peerAddress(fd)
                response = handler.handle(request)
            case .invalid(let r): response = r
            case .incomplete:
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { response = n == 0 ? nil : .error(408, "timeout", "request timed out"); if n == 0 { return } }
                else { buffer.append(chunk, count: n) }
            }
        }
        let bytes = [UInt8](response!.serialized())
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            sent += n
        }
    }
}
