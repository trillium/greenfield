import Foundation
import InserterCore

let usage = """
greenfield-inserter \(RequestHandler.version) - receives text over the tailnet and inserts it at the cursor

usage:
  greenfield-inserter serve [--port N] [--bind IP] [--name NAME] [--log-stderr]
  greenfield-inserter key create [--force]    make the key and show it once
  greenfield-inserter key status              say whether a key is set (never shows it)
  greenfield-inserter name [set NAME | reset] show or change the name the phone displays
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
    let handler = RequestHandler(keys: keys, probe: MacSystemProbe(), inserter: MacInserter(),
                                 name: { nameOverride ?? macName.current() }, logger: logger)
    logger.log("starting \(RequestHandler.serviceName) \(RequestHandler.version) name=\(nameOverride ?? macName.current())")
    if !keys.isConfigured { logger.log("no key configured; run `greenfield-inserter key create`") }
    if !MacSystemProbe().accessibilityTrusted { logger.log("Accessibility not granted; run `greenfield-inserter permissions`") }
    HTTPServer(target: target, port: port, handler: handler, logger: logger).run()

case "key":
    switch args.dropFirst().first {
    case "create":
        do {
            let key = try keys.create(force: args.contains("--force"))
            print("""
            Key for \(macName.current()) (shown once - enter it in the phone app now):

                \(key)

            Only a hash is stored in \(paths.keyFile.path); it cannot be shown again.
            """)
        } catch { fail("key create failed: \(error)") }
    case "status":
        print(keys.isConfigured ? "key configured (\(paths.keyFile.path))" : "no key configured")
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
