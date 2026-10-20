import AppKit

// A window with one text view. Every edit is mirrored to the file named by --out so a script
// can check exactly what an insertion produced. Usage: testfield --out /path/to/file
let args = CommandLine.arguments
guard let i = args.firstIndex(of: "--out"), i + 1 < args.count else {
    FileHandle.standardError.write(Data("usage: testfield --out FILE\n".utf8))
    exit(2)
}
let outPath = args[i + 1]

final class Delegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var textView: NSTextView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 520, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "testfield"
        textView = NSTextView(frame: window.contentView!.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isRichText = false
        textView.delegate = self
        window.contentView!.addSubview(textView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        try? "".write(toFile: outPath, atomically: true, encoding: .utf8)
        print("ready pid=\(getpid())")
        fflush(stdout)
    }

    func textDidChange(_ notification: Notification) {
        try? textView.string.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
