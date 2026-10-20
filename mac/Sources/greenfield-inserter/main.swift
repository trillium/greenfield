import Foundation
import InserterCore

let usage = """
greenfield-inserter \(RequestHandler.version) - receives text over the tailnet and inserts it at the cursor

usage:
  greenfield-inserter serve [--port N] [--bind IP] [--name NAME] [--log-stderr]
  greenfield-inserter key create [--force] [--out-file PATH]
                                              OPTIONAL: make a key for devices of other tailnet users; shown once
  greenfield-inserter key status              say whether the optional key is set (never shows it)
  greenfield-inserter name [set NAME | reset] show or change the name the phone displays
  greenfield-inserter macs add ALIAS HOST [--port N] [--key | --key-stdin] [--ssh USER@HOST]
                                              remember a Mac; no key is needed for your own tailnet user's devices
  greenfield-inserter macs list | remove ALIAS | show-key ALIAS
  greenfield-inserter macs check              GET /status on every remembered Mac: name, version, locked / secure input
  greenfield-inserter macs test [ALIAS] [--text STR]
                                              insert a harmless test string into that Mac's focused app
  greenfield-inserter health [--port N]       fast yes/no for this Mac's daemon; exit 0 only if everything is good
  greenfield-inserter doctor [--port N]       slower; for each failed check says what is wrong, why it matters and the fix
  greenfield-inserter macs health | doctor    the same for every remembered Mac, seen from here
  greenfield-inserter selftest [--port N]
                                              open a test window, send a test string and a Return through this Mac's
                                              own daemon, read them back; prints PASS or FAIL with the fix
  greenfield-inserter macs selftest ALIAS     run that on another Mac over ssh (see `macs ssh`)
  greenfield-inserter macs ssh ALIAS USER@HOST remember how to ssh to that Mac
  greenfield-inserter permissions             check Accessibility; ask macOS to prompt if missing

environment: GREENFIELD_INSERTER_HOME overrides ~/.config/greenfield-inserter
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value", code: 2) }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
let paths = InserterPaths.standard()
let keys = FileKeyStore(paths: paths)
let macName = MacName(paths: paths)

switch args.first ?? "serve" {
case "serve":
    let port = UInt16(option("--port", in: args) ?? "47821") ?? 0
    guard port != 0 else { fail("bad --port", code: 2) }
    let target: HTTPServer.BindTarget = option("--bind", in: args).map { .address($0) } ?? .tailnet
    let nameOverride = option("--name", in: args)
    try? paths.ensureDirectory()
    let logger = FileLogger(file: paths.logFile, echoToStderr: args.contains("--log-stderr"))
    var server: HTTPServer!
    let handler = RequestHandler(keys: keys, probe: MacSystemProbe(), inserter: MacInserter(),
                                 name: { nameOverride ?? macName.current() }, listening: { server.listening() },
                                 identity: TailscaleIdentity(), logger: logger)
    logger.log("starting \(RequestHandler.serviceName) \(RequestHandler.version) name=\(nameOverride ?? macName.current())")
    logger.log("authorization: loopback, same tailnet user\(keys.isConfigured ? ", or the optional key" : "") (no key needed)")
    if !MacSystemProbe().accessibilityTrusted { logger.log("Accessibility not granted; run `greenfield-inserter permissions`") }
    server = HTTPServer(target: target, port: port, handler: handler, logger: logger)
    server.run()

case "key":
    switch args.dropFirst().first {
    case "create":
        do {
            let key = try keys.create(force: args.contains("--force"))
            if let out = option("--out-file", in: args) {
                let line = key + "\n"
                let fd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                guard fd >= 0, Darwin.write(fd, line, line.utf8.count) == line.utf8.count else {
                    fail("key created but could not write \(out); run `key create --force` to try again")
                }
                close(fd)
                print("Key for \(macName.current()) written to \(out) (mode 0600). Move it where it is needed and delete it.")
                exit(0)
            }
            print("""
            Optional key for \(macName.current()) (shown once; only needed by devices of other tailnet users):

                \(key)

            Only a hash is stored in \(paths.keyFile.path); it cannot be shown again.
            """)
        } catch { fail("key create failed: \(error)") }
    case "status":
        print(keys.isConfigured ? "optional key set (\(paths.keyFile.path))" : "no key set (not needed: devices of this Mac's tailnet user are authorized by identity)")
    default: fail(usage, code: 2)
    }

case "name":
    switch args.dropFirst().first {
    case nil: print(macName.current())
    case "set":
        guard args.count >= 3 else { fail("name set needs a value", code: 2) }
        do { try macName.set(args.dropFirst(2).joined(separator: " ")); print(macName.current()) } catch { fail("\(error)") }
    case "reset": macName.clear(); print(macName.current())
    default: fail(usage, code: 2)
    }

case "health", "doctor":
    let port = Int(option("--port", in: args) ?? String(InserterDefaults.port)) ?? 0
    guard port > 0, port < 65536 else { fail("bad --port", code: 2) }
    let outcome = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health")
    var checks = snapshotChecks(outcome, subject: .local(port: port), localVersion: RequestHandler.version)
    let label = macName.current()
    if args[0] == "doctor" {
        var exe: String?
        if case .ok(let s) = outcome { exe = s.executable }
        checks = hostChecks(HostInspector.gather(paths: paths), daemonExecutable: exe) + checks
        let peers = MacRegistry(paths: paths).load()
        if !peers.isEmpty {
            checks += peerChecks(peers.map { InserterClient.check($0) }, localVersion: RequestHandler.version)
        } else {
            checks.append(HealthCheck("peers", "Other Macs reachable from here", .pass, detail: "none configured (`macs add` to add one)"))
        }
        print(formatDoctor(label: label, checks: checks))
    } else {
        print(formatHealth(label: label, checks: checks))
    }
    exit(isHealthy(checks) ? 0 : 1)

case "selftest":
    let port = Int(option("--port", in: args) ?? String(InserterDefaults.port)) ?? 0
    guard port > 0, port < 65536 else { fail("bad --port", code: 2) }
    let simulate = args.contains("--simulate-delivery")   // development only: proves the window, not delivery
    let observations = runSelftest(port: port, simulate: simulate)
    let checks = evaluateSelftest(observations)
    print(formatSelftest(label: macName.current(), checks: checks, simulated: simulate))
    exit(selftestPassed(checks) && !simulate ? 0 : 1)

case "macs":
    let registry = MacRegistry(paths: paths)
    let all = registry.load()
    func find(_ alias: String?) -> KnownMac {
        if let alias = alias {
            guard let m = all.first(where: { $0.alias == alias }) else { fail("no Mac with alias \(alias); see `macs list`") }
            return m
        }
        guard all.count == 1 else { fail("say which Mac: \(all.map(\.alias).joined(separator: ", "))", code: 2) }
        return all[0]
    }
    switch args.dropFirst().first {
    case "add":
        guard args.count >= 4 else { fail("usage: macs add ALIAS HOST [--port N] [--key | --key-stdin] [--ssh USER@HOST]", code: 2) }
        let port = Int(option("--port", in: args) ?? "47821") ?? 0
        guard port > 0, port < 65536 else { fail("bad --port", code: 2) }
        var key = ""
        if args.contains("--key-stdin") {
            key = readLine(strippingNewline: true) ?? ""
        } else if args.contains("--key") {
            guard isatty(0) == 1, let p = getpass("Key for \(args[2]) (hidden): ") else { fail("no terminal; pass --key-stdin") }
            key = String(cString: p)
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if (args.contains("--key") || args.contains("--key-stdin")) && key.isEmpty { fail("empty key") }
        let existing = all.first { $0.alias == args[2] }
        let ssh = option("--ssh", in: args) ?? existing?.ssh
        do { try registry.upsert(KnownMac(alias: args[2], host: args[3], port: port, key: key, ssh: ssh)); print("saved \(args[2])") }
        catch { fail("\(error)") }
    case "remove":
        guard args.count >= 3 else { fail("usage: macs remove ALIAS", code: 2) }
        do { try registry.remove(args[2]); print("removed \(args[2])") } catch { fail("\(error)") }
    case "list":
        for m in all { print("\(m.alias)  \(m.host):\(m.port)") }
    case "show-key":
        let saved = find(args.count >= 3 ? args[2] : nil)
        if saved.key.isEmpty { fail("no key saved for \(saved.alias) (none is needed for devices of the same tailnet user)") }
        print(saved.key)
    case "health", "doctor":
        guard !all.isEmpty else { fail("no Macs yet; add one with `macs add ALIAS HOST`") }
        var results = [(String, [HealthCheck])?](repeating: nil, count: all.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            let m = all[i]
            let outcome = InserterClient.snapshot(host: m.host, port: m.port, key: m.key, path: "/status")
            var label = m.alias
            if case .ok(let s) = outcome { label += " (\(s.name))" }
            let checks = snapshotChecks(outcome, subject: .remote(alias: m.alias, host: m.host, port: m.port), localVersion: RequestHandler.version)
            lock.lock(); results[i] = (label, checks); lock.unlock()
        }
        let done = results.compactMap { $0 }
        let doctor = args[1] == "doctor"
        print(done.map { doctor ? formatDoctor(label: $0.0, checks: $0.1) : formatHealth(label: $0.0, checks: $0.1) }
            .joined(separator: doctor ? "\n\n" : "\n"))
        exit(done.allSatisfy { isHealthy($0.1) } ? 0 : 1)
    case "ssh":
        guard args.count >= 4, let m = all.first(where: { $0.alias == args[2] }) else { fail("usage: macs ssh ALIAS USER@HOST (alias must exist)", code: 2) }
        var updated = m; updated.ssh = args[3]
        do { try registry.upsert(updated); print("saved ssh target for \(m.alias)") } catch { fail("\(error)") }
    case "selftest":
        guard args.count >= 3 else { fail("usage: macs selftest ALIAS", code: 2) }
        let m = find(args[2])
        let remoteBinary = option("--remote-binary", in: args) ?? ".local/share/greenfield-inserter/greenfield-inserter"
        let isHere = ["localhost", "127.0.0.1"].contains(m.host) || m.host.split(separator: ".").first.map(String.init) == MacName.hostname()
        let command: [String]
        if isHere {
            command = [CommandLine.arguments[0], "selftest", "--port", String(m.port)]
        } else if let target = m.ssh {
            command = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target,
                       "\(remoteBinary) selftest --port \(m.port)"]
        } else {
            fail("no ssh target for \(m.alias); add one with `macs ssh \(m.alias) USER@HOST`, or run `greenfield-inserter selftest` on that Mac")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        do { try p.run() } catch { fail("could not run \(command[0]): \(error)") }
        p.waitUntilExit()
        exit(p.terminationStatus)
    case "check":
        guard !all.isEmpty else { fail("no Macs yet; add one with `macs add ALIAS HOST`") }
        var reports = [MacReport?](repeating: nil, count: all.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            let r = InserterClient.check(all[i]); lock.lock(); reports[i] = r; lock.unlock()
        }
        let done = reports.compactMap { $0 }
        print(formatReports(done))
        exit(done.contains { $0.needsAttention } ? 1 : 0)
    case "test":
        let mac = find(args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : nil)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = option("--text", in: args) ?? "greenfield test \(stamp) "
        let result = InserterClient.sendText(text, to: mac)
        print("\(mac.alias): \(result.summary)")
        exit(result.inserted ? 0 : 1)
    default: fail(usage, code: 2)
    }

case "permissions":
    let probe = MacSystemProbe()
    if probe.accessibilityTrusted {
        print("Accessibility: granted")
    } else {
        _ = MacSystemProbe.requestAccessibilityPrompt()
        print("""
        Accessibility: NOT granted. macOS should now show "greenfield-inserter would like to control this computer using accessibility features".
        Click "Open System Settings" and switch greenfield-inserter on under Privacy & Security > Accessibility.
        """)
        exit(1)
    }

case "-h", "--help", "help": print(usage)
default: fail(usage, code: 2)
}
