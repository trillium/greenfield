import XCTest
@testable import InserterCore

final class PeersTests: XCTestCase {
    static let status = """
    {"Self":{"HostName":"mini0","DNSName":"mini0.t.ts.net.","TailscaleIPs":["100.64.0.1","fd7a::1"],"UserID":10,"Online":true,"OS":"macOS"},
     "Peer":{
      "k1":{"HostName":"localhost","DNSName":"iphone.t.ts.net.","TailscaleIPs":["100.64.0.2"],"UserID":10,"Online":true,"OS":"iOS"},
      "k2":{"HostName":"book","DNSName":"macbook.t.ts.net.","TailscaleIPs":["100.64.0.3","fd7a::3"],"UserID":10,"Online":true,"OS":"macOS"},
      "k3":{"HostName":"asleep","DNSName":"mini9.t.ts.net.","TailscaleIPs":["100.64.0.4"],"UserID":10,"Online":false,"OS":"macOS"},
      "k4":{"HostName":"theirs","DNSName":"friend.t.ts.net.","TailscaleIPs":["100.64.0.5"],"UserID":99,"Online":true,"OS":"macOS"},
      "k5":{"HostName":"box","DNSName":"lnx.t.ts.net.","TailscaleIPs":["100.64.0.6"],"UserID":10,"Online":true,"OS":"linux"},
      "k6":{"HostName":"nobody","DNSName":"quiet.t.ts.net.","TailscaleIPs":["100.64.0.7"],"UserID":10,"Online":true,"OS":"macOS"}}}
    """

    func snapshot(_ name: String, version: String = "0.2.2") -> DaemonSnapshot {
        DaemonSnapshot(name: name, version: version, listen: [], accessibility: true, screenLocked: false, secureInput: false,
                       keyConfigured: false, executable: nil, pid: nil)
    }

    func testParsesTheTailnetStatus() throws {
        let (me, peers) = try XCTUnwrap(TailnetStatus.parse(Data(Self.status.utf8)))
        XCTAssertEqual(me.dnsName, "mini0.t.ts.net"); XCTAssertEqual(me.ip, "100.64.0.1")
        XCTAssertEqual(peers.count, 6)
        XCTAssertEqual(peers.first { $0.hostName == "book" }?.ip, "100.64.0.3")        // the IPv4, not the fd7a one
        XCTAssertNil(TailnetStatus.parse(Data("nope".utf8)))
    }

    func testOnlyOnlineSameUserMacsAreProbed() {
        var probed: [String] = []
        let lock = NSLock()
        let d = TailnetDiscovery(statusJSON: { Data(Self.status.utf8) },
            probe: { node in
                lock.lock(); probed.append(node.dnsName); lock.unlock()
                return node.dnsName == "macbook.t.ts.net" ? self.snapshot("Trillium's MacBook Pro") : nil    // quiet.t.ts.net runs no daemon
            }, myName: { "mini0" }, myVersion: "0.2.2")
        let found = d.computers()
        XCTAssertEqual(Set(probed), ["macbook.t.ts.net", "quiet.t.ts.net"])         // not the phone, linux, offline or another user's Mac
        XCTAssertEqual(found.map(\.address), ["mini0.t.ts.net", "macbook.t.ts.net"])
        XCTAssertEqual(found.map(\.isSelf), [true, false])
        XCTAssertEqual(found[1].name, "Trillium's MacBook Pro"); XCTAssertEqual(found[1].version, "0.2.2")
    }

    func testResultsAreCachedBriefly() {
        var calls = 0
        var t = Date(timeIntervalSince1970: 0)
        let d = TailnetDiscovery(statusJSON: { Data(Self.status.utf8) }, probe: { _ in calls += 1; return nil },
                                 myName: { "m" }, myVersion: "1", now: { t })
        _ = d.computers(); let first = calls
        _ = d.computers()
        XCTAssertEqual(calls, first)
        t += 30; _ = d.computers()
        XCTAssertGreaterThan(calls, first)
    }

    func testNoTailscaleMeansAnEmptyList() {
        XCTAssertEqual(TailnetDiscovery(statusJSON: { nil }, probe: { _ in nil }, myName: { "m" }, myVersion: "1").computers(), [])
    }

    func testAddLinkRoundTrips() throws {
        for name in ["mini0", "Trillium's MacBook Pro", "A&B = C+D #1", "héllo 👋"] {
            let link = AddLink.make(name: name, address: "mini0.t.ts.net")
            XCTAssertTrue(link.hasPrefix("greenfield://add?name="), link)
            XCTAssertFalse(link.dropFirst("greenfield://add?".count).contains(" "))
            let parsed = try XCTUnwrap(AddLink.parse(link), link)
            XCTAssertEqual(parsed.name, name); XCTAssertEqual(parsed.address, "mini0.t.ts.net")
        }
        XCTAssertNil(AddLink.parse("https://example.com/add?name=x&address=y"))
        XCTAssertNil(AddLink.parse("greenfield://add?name=x"))
    }

    func testBonjourRecordCarriesTheTailnetAddress() {
        let txt = BonjourAdvertiser.txtRecord(name: "mini0", address: "mini0.t.ts.net", version: "0.2.2")
        XCTAssertEqual(String(data: txt["address"]!, encoding: .utf8), "mini0.t.ts.net")
        XCTAssertEqual(String(data: txt["name"]!, encoding: .utf8), "mini0")
        XCTAssertEqual(BonjourAdvertiser.serviceType, "_greenfield._tcp.")
        XCTAssertNoThrow(NetService.data(fromTXTRecord: txt))
    }

    // MARK: GET /peers

    final class Identity: TailnetIdentity {
        var result: PeerIdentity = .sameUser(login: "me")
        func identify(_ address: String) -> PeerIdentity { result }
        func selfLogin() -> String? { "me" }
    }
    final class Fixed: ComputerDiscovery {
        func computers() -> [DiscoveredComputer] {
            [DiscoveredComputer(name: "mini0", address: "mini0.t.ts.net", version: "0.2.2", isSelf: true),
             DiscoveredComputer(name: "MacBook", address: "macbook.t.ts.net", version: "0.2.2", isSelf: false)]
        }
    }

    func peersCall(identity: PeerIdentity, key: String? = nil, loopback: Bool = false, discovery: ComputerDiscovery? = Fixed()) -> HTTPResponse {
        let id = Identity(); id.result = identity
        let h = RequestHandler(keys: StubKeys(), probe: StubProbe(), inserter: SpyInserter(), name: { "m" }, identity: id, discovery: discovery)
        var headers: [String: String] = [:]
        if let key = key { headers["x-dictation-key"] = key }
        return h.handle(HTTPRequest(method: "GET", path: "/peers", headers: headers, fromLoopback: loopback, peerAddress: "100.64.0.9"))
    }

    func testPeersListsComputersToSameUserDevices() throws {
        let r = peersCall(identity: .sameUser(login: "me"))
        XCTAssertEqual(r.status, 200)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        let peers = try XCTUnwrap(o["peers"] as? [[String: Any]])
        XCTAssertEqual(peers.map { $0["address"] as? String }, ["mini0.t.ts.net", "macbook.t.ts.net"])
        for p in peers { for k in ["name", "address", "version"] { XCTAssertNotNil(p[k] as? String, k) } }     // the phone's shape
        XCTAssertEqual(peersCall(identity: .unknown("x"), loopback: true).status, 200)
    }

    func testPeersIsNotShownToOtherUsersOrToKeyOnlyCallers() {
        XCTAssertEqual(peersCall(identity: .otherUser(login: "x")).status, 401)
        XCTAssertEqual(peersCall(identity: .otherUser(login: "x"), key: "good").status, 403)       // the key opens /status and /text, not the tailnet list
        XCTAssertEqual(peersCall(identity: .unknown("down")).status, 503)                          // fails closed
    }

    func testPeersWithoutDiscoveryIsAnEmptyList() throws {
        let r = peersCall(identity: .sameUser(login: "me"), discovery: nil)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["peers"] as? [Any])?.count, 0)
    }
}
