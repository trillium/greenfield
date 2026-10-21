import SwiftUI

/// Benchmark host: `-spike-engine <id>[,<id>]` runs headless and exits (`-spike-exit YES`), otherwise tap an engine to run it.
/// Results go to the console as `SPIKE-RESULT <json>` and to Documents/spike-results.jsonl.
@main
struct SpikeApp: App {
    @State private var model = SpikeModel()

    var body: some Scene {
        WindowGroup {
            SpikeView(model: model)
                .task { await model.autoRun() }
        }
    }
}

@MainActor
@Observable
final class SpikeModel {
    var lines: [String] = []
    var running = false

    func append(_ line: String) {
        lines.append(line)
        print("SPIKE \(line)")
    }

    func autoRun() async {
        UIApplication.shared.isIdleTimerDisabled = true
        let args = UserDefaults.standard
        guard let ids = args.string(forKey: "spike-engine") else { return }
        let tag = args.string(forKey: "spike-tag") ?? "run"
        let loop = args.integer(forKey: "spike-loop")
        for id in ids.split(separator: ",").map(String.init) { await run(id, tag: tag, loop: loop) }
        append("done")
        if args.bool(forKey: "spike-exit") { exit(0) }
    }

    func run(_ id: String, tag: String, loop: Int) async {
        running = true
        defer { running = false }
        let runner = SpikeRunner { [weak self] line in Task { @MainActor in self?.append(line) } }
        let report = await runner.run(engineID: id, tag: tag, loopCount: loop)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else { return }
        print("SPIKE-RESULT \(json)")
        let wer = String(format: "%.1f", report.wer * 100)
        append("\(id): load \(Int(report.loadMs)) ms, p50 \(Int(report.latencyP50Ms)) ms, WER \(wer)%, peak \(Int(report.peakMB)) MB")
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let documents = folder.appendingPathComponent("spike-results.jsonl")
        let line = Data((json + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: documents) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: documents)
        }
    }
}

struct SpikeView: View {
    let model: SpikeModel

    var body: some View {
        NavigationStack {
            List {
                Section("Run an engine") {
                    ForEach(SpikeEngines.all, id: \.self) { id in
                        Button(id) { Task { await model.run(id, tag: "manual", loop: 0) } }.disabled(model.running)
                    }
                }
                Section("Log") {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Dictation spike")
        }
    }
}
