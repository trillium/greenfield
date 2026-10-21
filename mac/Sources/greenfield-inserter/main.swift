import Foundation
import InserterCore

let usage = """
greenfield-inserter \(RequestHandler.version) - receives text over the tailnet and inserts it at the cursor

usage:
  greenfield-inserter serve [--port N] [--bind IP] [--name NAME] [--log-stderr]
  greenfield-inserter key create [--force] [--out-file PATH]
                                              OPTIONAL: make a key for devices of other tailnet users; shown once
  greenfield-inserter key status              say whether the optional key is set (never shows it)
  greenfield-inserter pair [--list | --revoke ID | --revoke-all] [--port N]
                                              a one-time code for a browser (the PWA) outside the tailnet; list or revoke paired devices
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
  greenfield-inserter logs [--tail N] [--since 30m]
                                              this Mac's daemon log, redacted (no text, no keys); works with the daemon stopped
  greenfield-inserter macs logs ALIAS [--tail N] [--since 30m]
                                              that Mac's daemon log over the tailnet (GET /logs), redacted
  greenfield-inserter assist [status]         the assist tools (window switcher, trackpad) for the phone: what is on
  greenfield-inserter assist on | off         the master switch; OFF by default, and `off` closes every pointer session at once
  greenfield-inserter assist windows|focus|pointer|titles on|off
                                              one tool or setting at a time (pointer is off until turned on here)
  greenfield-inserter assist check-windows    the live check: opens two throwaway windows of its own, lists, focuses, closes them
  greenfield-inserter selftest [--port N]
                                              open a test window, send a test string and a Return through this Mac's
                                              own daemon, read them back; prints PASS or FAIL with the fix
  greenfield-inserter macs selftest ALIAS     run that on another Mac over ssh (see `macs ssh`)
  greenfield-inserter macs ssh ALIAS USER@HOST remember how to ssh to that Mac
  greenfield-inserter ready                   "am I ready?": says ready, or exactly one next step in plain words (exit 0 only if ready)
  greenfield-inserter setup [--timeout S] [--no-open] [--no-selftest]
                                              the guided finish: opens the Accessibility pane, shows a live checklist that turns
                                              green as each step lands, proves delivery, then prints the add link and QR
  greenfield-inserter link [--no-qr | --dark-terminal]          the greenfield://add link (and a QR code) that adds this Mac to the phone with no typing
  greenfield-inserter version                 the version, commit and binary hash of this file
  greenfield-inserter restart                 bootout + bootstrap the launchd agent; wait until the running build is the installed file
  greenfield-inserter update --from FILE      install a new (signed) build, restart, verify it is the one running; roll back if it does not come up
  greenfield-inserter verify-running          is the running daemon the installed file? (exit 0 if so)
  greenfield-inserter macs restart ALIAS      run `restart` on another Mac over ssh (see `macs ssh`)
  greenfield-inserter permissions             check Accessibility; ask macOS to prompt if missing

port: --port, else GREENFIELD_PORT from the environment, else GREENFIELD_PORT in the nearest .env (see .env.example), else the built-in default
  greenfield-inserter port                    print the port this Mac uses (what the installer reads)
environment: GREENFIELD_INSERTER_HOME overrides ~/.config/greenfield-inserter
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// `--tail N` and `--since 30m` as the same query `GET /logs` takes, so both fail the same way.
func logQuery(_ args: [String]) -> Result<LogQuery, LogQueryError> {
    var parts: [String] = []
    if let tail = option("--tail", in: args) { parts.append("tail=\(tail)") }
    if let since = option("--since", in: args) { parts.append("since=\(since)") }
    return LogQuery.parse(query: parts.joined(separator: "&"))
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

/// The port from `--port`, the environment, `.env`, else the default in `InserterDefaults`; stops with a hint when it is not a number.
func configuredPort(_ args: [String]) -> UInt16 {
    let dotEnv = DotEnv.load(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    switch DotEnv.port(flag: option("--port", in: args), environment: ProcessInfo.processInfo.environment, dotEnv: dotEnv) {
    case .success(let port): return port
    case .failure(let error): fail("\(error)", code: 2)
    }
}

switch args.first ?? "serve" {
case "port":
    print(configuredPort(args))

case "serve":
    let port = configuredPort(args)
    let target: HTTPServer.BindTarget = option("--bind", in: args).map { .address($0) } ?? .tailnet
    let nameOverride = option("--name", in: args)
    try? paths.ensureDirectory()
    let logger = FileLogger(file: paths.logFile, echoToStderr: args.contains("--log-stderr"))
    let tailscale = TailscaleIdentity()
    let discovery = TailnetDiscovery(
        statusJSON: { tailscale.statusData() },
        probe: { node in
            if case .ok(let s) = InserterClient.snapshot(host: node.ip, port: Int(port), key: nil, path: "/status", timeout: 1.5) { return s }
            return nil
        },
        myName: { nameOverride ?? macName.current() }, myVersion: BuildInfo.version)
    var server: HTTPServer!
    // The assist tools. Everything is off until `greenfield-inserter assist on`; the settings file is read on every request.
    let assistSettings = FileAssistSettings(paths: paths)
    let systemProbe = MacSystemProbe()
    let windowService = WindowService(provider: MacWindowProvider(), probe: systemProbe, settings: assistSettings,
                                      computerName: { nameOverride ?? macName.current() })
    let datagramAddress: () -> String? = { if case .address(let a) = target { return a }; return Tailnet.ipv4() }
    let transport = UDPPointerTransport(address: datagramAddress, port: port, logger: logger)
    let pointer = PointerService(settings: assistSettings, probe: systemProbe, sink: CGEventPointerSink(), listener: transport, logger: logger)
    transport.service = pointer
    let assist = AssistEndpoints(settings: assistSettings, windows: windowService, pointer: pointer, endpoint: { transport.endpoint }, logger: logger)
    let handler = RequestHandler(keys: keys, probe: MacSystemProbe(), inserter: MacInserter(),
                                 name: { nameOverride ?? macName.current() }, listening: { server.listening() },
                                 identity: tailscale, record: DeliveryLedger(paths: paths), clients: ClientLedger(paths: paths), discovery: discovery, assist: assist, logger: logger,
                                 logSource: FileLogSource(file: paths.logFile))
    logger.log("starting \(RequestHandler.serviceName) \(RequestHandler.version) name=\(nameOverride ?? macName.current())")
    logger.log("who may call: loopback, same tailnet user\(keys.isConfigured ? ", or the optional key" : "") (no key needed)")
    if !MacSystemProbe().accessibilityTrusted { logger.log("Accessibility not granted; run `greenfield-inserter permissions`") }
    let startSettings = assistSettings.current()
    logger.log("assist tools: \(startSettings.enabled ? "ON" : "off") windows=\(startSettings.windowsAvailable) pointer=\(startSettings.pointerAvailable) (greenfield-inserter assist status)")
    if !args.contains("--no-bonjour") {
        // the service record carries the tailnet name, because the daemon is not reachable on the LAN itself
        let ownAddress = tailscale.statusData().flatMap(TailnetStatus.parse)?.me.dnsName ?? Tailnet.ipv4() ?? "unknown"
        BonjourAdvertiser().start(name: nameOverride ?? macName.current(), address: ownAddress, version: BuildInfo.version, port: Int(port), log: { logger.log($0) })
    }
    MacSystemProbe.restartWhenAccessibilityIsGranted { logger.log($0) }
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

case "pair":
    let port = Int(configuredPort(args))
    func ask(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (status: Int, body: [String: Any]) {
        guard let answer = InserterClient.local(port: port, method: method, path: path, body: body) else {
            fail("the daemon is not answering on 127.0.0.1:\(port); start it (`greenfield-inserter serve`) or check `greenfield-inserter health`")
        }
        return answer
    }
    func ensureOK(_ answer: (status: Int, body: [String: Any])) {
        guard !(answer.status == 404 && answer.body["error"] as? String == "not_found") else { fail("this daemon predates browser pairing; update it (`make -C mac install`)") }
        guard answer.status == 200 else { fail("\(answer.body["message"] as? String ?? "HTTP \(answer.status)")") }
    }
    if args.contains("--list") {
        let answer = ask("GET", "/pair/devices")
        ensureOK(answer)
        let list = answer.body["devices"] as? [[String: Any]] ?? []
        if list.isEmpty { print("no paired devices") }
        for d in list {
            print("\(d["id"] as? String ?? "?")  \(d["name"] as? String ?? "?")  expires \(d["expires_at"] as? String ?? "?")  last seen \((d["last_seen"] as? String) ?? "never")")
        }
    } else if args.contains("--revoke-all") {
        let answer = ask("POST", "/pair/revoke", ["all": true])
        ensureOK(answer)
        print("revoked \(answer.body["revoked"] as? Int ?? 0) device(s); any open code is gone too")
    } else if let id = option("--revoke", in: args) {
        ensureOK(ask("POST", "/pair/revoke", ["id": id]))
        print("revoked \(id)")
    } else {
        let answer = ask("POST", "/pair/code")
        ensureOK(answer)
        let minutes = (answer.body["expires_in_s"] as? Int ?? 300) / 60
        print("""
        Pairing code for \(answer.body["name"] as? String ?? "this Mac"):

            \(answer.body["code"] as? String ?? "?")

        Type it into the Greenfield web app (Computers > Pair) within \(minutes) minutes. It works once.
        The browser gets a token for 24 hours that only sends text; `greenfield-inserter pair --list` shows it, `--revoke ID` ends it.
        """)
    }

case "logs":
    switch logQuery(args) {
    case .failure(let e): fail("logs: \(e.message)", code: 2)
    case .success(let query):
        let source = FileLogSource(file: paths.logFile)
        guard source.available else { fail("no log yet at \(paths.logFile.path); the daemon creates it when it starts") }
        let page = LogPage.build(lines: source.read(query, now: Date()), query: query)
        page.lines.forEach { print($0) }
        if page.truncated { FileHandle.standardError.write(Data("(showing the newest \(page.lines.count) lines; --tail N asks for more, up to \(LogQuery.maxTail))\n".utf8)) }
    }

case "assist":
    let settingsFile = FileAssistSettings(paths: paths)
    func describe(_ s: AssistSettings) -> String {
        func word(_ on: Bool) -> String { on ? "on " : "off" }
        return """
        assist tools: \(s.enabled ? "ON" : "OFF") (the master switch; default off)
          window switcher   list: \(word(s.windowsAvailable))  focus: \(word(s.windowsAvailable && s.focus))  titles leave this Mac: \(word(s.titles))
          trackpad (pointer) \(word(s.pointerAvailable))   (own switch, off until `assist pointer on`; live pointer injection has not been approved yet)
        settings file: \(paths.assistFile.path)
        """
    }
    func change(_ edit: (inout AssistSettings) -> Void) -> AssistSettings {
        do { return try settingsFile.update(edit) } catch { fail("could not save \(paths.assistFile.path): \(error)") }
    }
    let rest = Array(args.dropFirst())
    switch rest.first ?? "status" {
    case "status": print(describe(settingsFile.current()))
    case "on": print(describe(change { $0.enabled = true }))
    case "off":
        print(describe(change { $0.enabled = false }))
        print("The running daemon follows within a second: pointer sessions are closed and the assist routes answer 404.")
    case "windows", "focus", "pointer", "titles":
        guard rest.count == 2, rest[1] == "on" || rest[1] == "off" else { fail("usage: assist \(rest[0]) on|off", code: 2) }
        let on = rest[1] == "on"
        print(describe(change {
            switch rest[0] {
            case "windows": $0.windows = on
            case "focus": $0.focus = on
            case "pointer": $0.pointer = on
            default: $0.titles = on
            }
        }))
    case "check-windows": exit(LiveWindowCheck().run())
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
    let port = Int(configuredPort(args))
    var outcome = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health")
    if args[0] == "doctor", !args.contains("--no-selftest"), case .ok = outcome,
       snapshotChecks(outcome, subject: .local(port: port), localVersion: RequestHandler.version)
           .allSatisfy({ $0.id == "can-insert" || $0.status == .pass }) {
        // Everything else is fine: prove delivery for real (opens a small window for a few seconds).
        let live = evaluateSelftest(runSelftest(port: port, simulate: false))
        recordSelftestEvidence(live, ledger: DeliveryLedger(paths: paths))
        outcome = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health")
    }
    var checks = snapshotChecks(outcome, subject: .local(port: port), localVersion: RequestHandler.version)
    let label = macName.current()
    if args[0] == "doctor" {
        var exe: String?
        var running: BuildIdentity?
        var uptime: Int?
        if case .ok(let s) = outcome { exe = s.executable; running = s.build; uptime = s.uptime }
        checks = hostChecks(HostInspector.gather(paths: paths), daemonExecutable: exe, running: running, uptime: uptime) + checks
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

case "ready", "setup":
    let port = Int(configuredPort(args))
    let label = option("--label", in: args) ?? InserterDefaults.launchdLabel
    let binary = option("--install-to", in: args) ?? InserterDefaults.installedBinary
    func checks() -> [HealthCheck] { gatherLocalChecks(paths: paths, port: port, label: label, binary: binary) }
    func addLink() -> String? {
        let address = TailscaleIdentity().statusData().flatMap(TailnetStatus.parse)?.me.dnsName ?? Tailnet.ipv4()
        return address.map { AddLink.make(name: macName.current(), address: $0) }
    }

    if args[0] == "ready" {
        switch readiness(checks: checks(), bin: binary) {
        case .ready(let notes):
            print("Ready." + (notes.isEmpty ? "" : " (Note: " + notes.joined(separator: "; ") + ".)"))
            exit(0)
        case .next(let step):
            print("Not ready yet. Next step: \(step)")
            exit(1)
        }
    }

    // setup: a live checklist that turns green as each step lands
    let timeout = Double(option("--timeout", in: args) ?? "600") ?? 600
    let interactive = isatty(1) == 1
    let started = Date()
    var drawnLines = 0
    var lastPlain = ""
    var raisedPrompt = false, ranSelftest = false
    print("Setting up Greenfield on \(macName.current()). This screen updates by itself; you do not need to press anything.\n")
    while true {
        let current = checks()
        let rows = setupRows(checks: current)
        let verdict = readiness(checks: current, bin: binary)
        let waiting = rows.first { $0.state == .waiting }
        var headline = "Waiting for you:"
        if case .next(let step) = verdict { headline = "Next: \(step)" } else { headline = "Everything is in place." }
        let text = renderSetup(rows: rows, headline: headline)
        if interactive {
            if drawnLines > 0 { print("\u{1B}[\(drawnLines)A\u{1B}[J", terminator: "") }
            print(text); drawnLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        } else if text != lastPlain { print(text + "\n"); lastPlain = text }

        if verdict.isReady { break }
        if waiting?.title == "Accessibility approved", !raisedPrompt {
            raisedPrompt = true
            _ = MacSystemProbe.requestAccessibilityPrompt()      // makes macOS list greenfield-inserter and show its prompt
            if !args.contains("--no-open") {
                _ = HostInspector.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
            }
        }
        // Accessibility is in and everything else is fine: prove delivery for real, once.
        if waiting?.title == "Text really reaches apps", !ranSelftest, !args.contains("--no-selftest") {
            ranSelftest = true
            let live = evaluateSelftest(runSelftest(port: port, simulate: false))
            recordSelftestEvidence(live, ledger: DeliveryLedger(paths: paths))
            if !selftestPassed(live) { print("\n" + formatSelftest(label: macName.current(), checks: live, simulated: false)); exit(1) }
            continue
        }
        if Date().timeIntervalSince(started) > timeout {
            if case .next(let step) = verdict { print("\nStill waiting after \(Int(timeout)) seconds. Next step: \(step)") }
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1)
    }
    if case .ready(let notes) = readiness(checks: checks(), bin: binary) {
        print("\nReady." + (notes.isEmpty ? "" : " (Note: " + notes.joined(separator: "; ") + ".)") + " Add this Mac to the phone: open the link below on the phone, or scan the code.\n")
        if let link = addLink() {
            print("  \(link)\n")
            if let qr = terminalQR(link, forDarkTerminal: interactive) { print(qr) }
        }
    }
    exit(0)

case "link":
    let tailscale = TailscaleIdentity()
    let address = tailscale.statusData().flatMap(TailnetStatus.parse)?.me.dnsName ?? Tailnet.ipv4()
    guard let address = address else { fail("this Mac has no tailnet address; is Tailscale running?") }
    let link = AddLink.make(name: macName.current(), address: address)
    print("Add \(macName.current()) to the phone: open this link on the phone, or scan the code.\n\n  \(link)\n")
    if !args.contains("--no-qr"), let qr = terminalQR(link, forDarkTerminal: args.contains("--dark-terminal")) { print(qr) }

case "version", "--version", "-v":
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    print("greenfield-inserter \(BuildInfo.fullVersion) commit \(BuildInfo.commit) binary \(RunningBuild.sha256Prefix(ofFile: exe) ?? "unknown") build \(BuildInfo.build)")

case "restart", "verify-running", "update":
    let port = Int(configuredPort(args))
    let label = option("--label", in: args) ?? InserterDefaults.launchdLabel
    let installed = option("--install-to", in: args) ?? InserterDefaults.installedBinary
    let installedSha = LaunchAgent.sha(of: installed)
    func describe(_ b: BuildIdentity) -> String { "\(b.version) (commit \(b.commit), binary \(b.binarySha))" }

    switch args[0] {
    case "verify-running":
        let running = LaunchAgent.waitForRunning(port: port, expectedSha: installedSha, timeout: Double(option("--wait", in: args) ?? "20") ?? 20)
        switch judgeRunning(running: running, installedSha: installedSha) {
        case .match: print("running \(describe(running!)) is the installed file"); exit(0)
        case .restartNeeded(let r, let i): fail("running build (binary \(r)) is not the installed file (binary \(i)): restart needed")
        case .notRunning: fail("the daemon is not answering on port \(port)")
        case .unknown(let why): fail("cannot verify: \(why)")
        }
    case "restart":
        do { try LaunchAgent.restart(label: label) } catch { fail("restart failed: \(error)") }
        let running = LaunchAgent.waitForRunning(port: port, expectedSha: installedSha)
        guard let r = running, r.binarySha == installedSha else {
            fail(running == nil ? "restarted, but the daemon did not answer on port \(port) within 20 seconds"
                                : "restarted, but the running build (\(describe(running!))) is not the installed file")
        }
        print("restarted: running \(describe(r))")
    default:   // update
        guard let from = option("--from", in: args) else { fail("usage: update --from FILE", code: 2) }
        guard FileManager.default.isExecutableFile(atPath: from), let newSha = LaunchAgent.sha(of: from) else { fail("\(from) is not an executable file") }
        let verify = HostInspector.run("/usr/bin/codesign", ["--verify", "--strict", from])
        guard verify.status == 0 else { fail("\(from) does not have a valid signature; refusing to install it (an unsigned build would lose the Accessibility approval)") }
        let fm = FileManager.default
        let previous = installed + ".previous"
        let previousSha = installedSha          // what is installed now, before anything is replaced
        let flow = UpdateFlow(
            installNew: {
                try fm.createDirectory(atPath: (installed as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: installed) {
                    try? fm.removeItem(atPath: previous)
                    try fm.copyItem(atPath: installed, toPath: previous)
                }
                let tmp = installed + ".new"
                try? fm.removeItem(atPath: tmp)
                try fm.copyItem(atPath: from, toPath: tmp)
                if rename(tmp, installed) != 0 { throw KeyStoreError.io("could not move the new build into place (errno \(errno))") }
            },
            restorePrevious: {
                guard fm.fileExists(atPath: previous) else { return false }
                let tmp = installed + ".restore"
                try? fm.removeItem(atPath: tmp)
                try fm.copyItem(atPath: previous, toPath: tmp)
                if rename(tmp, installed) != 0 { throw KeyStoreError.io("could not restore the previous build") }
                return true
            },
            restart: { try LaunchAgent.restart(label: label) },
            waitForRunning: { LaunchAgent.waitForRunning(port: port, expectedSha: nil, timeout: 20) },
            newSha: newSha, previousSha: previousSha)
        // waitForRunning above returns whatever is running; give the new build a moment to replace the old one.
        var flowWithWait = flow
        let expectedSha = newSha
        flowWithWait.waitForRunning = { LaunchAgent.waitForRunning(port: port, expectedSha: expectedSha, timeout: 20) }
        switch flowWithWait.run() {
        case .updated(let v): print("updated: running \(v) (binary \(newSha)) from \(installed)")
        case .rolledBack(let why):
            let prev = previousSha
            var line = "UPDATE FAILED and was rolled back: \(why)."
            if let prev = prev { line += " The previous build (binary \(prev)) is running again." }
            fail(line)
        case .failed(let why): fail("UPDATE FAILED: \(why)")
        }
    }

case "selftest":
    let port = Int(configuredPort(args))
    let simulate = args.contains("--simulate-delivery")   // development only: proves the window, not delivery
    let observations = runSelftest(port: port, simulate: simulate)
    let checks = evaluateSelftest(observations)
    if !simulate { recordSelftestEvidence(checks, ledger: DeliveryLedger(paths: paths)) }
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
        let port = Int(configuredPort(args))
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
    case "logs":
        guard args.count >= 3, !args[2].hasPrefix("--") else { fail("usage: macs logs ALIAS [--tail N] [--since 30m]", code: 2) }
        let m = find(args[2])
        switch logQuery(args) {
        case .failure(let e): fail("macs logs: \(e.message)", code: 2)
        case .success(let query):
            switch InserterClient.fetchLogs(m, query: query) {
            case .lines(let lines, let truncated):
                lines.forEach { print($0) }
                if truncated { FileHandle.standardError.write(Data("(\(m.alias): showing the newest \(lines.count) lines; --tail N asks for more)\n".utf8)) }
            case .failed(let why): fail(why)
            }
        }
    case "ssh":
        guard args.count >= 4, let m = all.first(where: { $0.alias == args[2] }) else { fail("usage: macs ssh ALIAS USER@HOST (alias must exist)", code: 2) }
        var updated = m; updated.ssh = args[3]
        do { try registry.upsert(updated); print("saved ssh target for \(m.alias)") } catch { fail("\(error)") }
    case "restart":
        guard args.count >= 3 else { fail("usage: macs restart ALIAS", code: 2) }
        let m = find(args[2])
        let isHere = ["localhost", "127.0.0.1"].contains(m.host) || m.host.split(separator: ".").first.map(String.init) == MacName.hostname()
        let command: [String]
        if isHere { command = [CommandLine.arguments[0], "restart", "--port", String(m.port)] }
        else if let target = m.ssh {
            command = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target,
                       ".local/share/greenfield-inserter/greenfield-inserter restart --port \(m.port)"]
        } else { fail("no ssh target for \(m.alias); add one with `macs ssh \(m.alias) USER@HOST`") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0]); p.arguments = Array(command.dropFirst())
        do { try p.run() } catch { fail("could not run \(command[0]): \(error)") }
        p.waitUntilExit()
        exit(p.terminationStatus)
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
