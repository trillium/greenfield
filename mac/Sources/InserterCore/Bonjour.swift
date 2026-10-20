import Foundation

/// Advertises `_greenfield._tcp` so a phone on the same network can find a seed without typing. The service record
/// carries this Mac's name and its tailnet (MagicDNS) address, because the daemon itself only listens on the
/// tailnet and loopback: the phone connects to `address`, not to the LAN address Bonjour would resolve.
public final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    public static let serviceType = "_greenfield._tcp."
    private var service: NetService?

    public static func txtRecord(name: String, address: String, version: String) -> [String: Data] {
        ["name": Data(name.utf8), "address": Data(address.utf8), "version": Data(version.utf8), "path": Data("/status".utf8)]
    }

    public func start(name: String, address: String, version: String, port: Int, log: @escaping (String) -> Void) {
        let thread = Thread { [self] in
            let svc = NetService(domain: "local.", type: BonjourAdvertiser.serviceType, name: name, port: Int32(port))
            svc.delegate = self
            svc.setTXTRecord(NetService.data(fromTXTRecord: BonjourAdvertiser.txtRecord(name: name, address: address, version: version)))
            svc.schedule(in: .current, forMode: .common)
            svc.publish()
            service = svc
            log("advertising \(BonjourAdvertiser.serviceType) as \"\(name)\" (address \(address))")
            RunLoop.current.run()
        }
        thread.name = "bonjour"
        thread.start()
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        FileHandle.standardError.write(Data("bonjour: could not publish: \(errorDict)\n".utf8))
    }
}
