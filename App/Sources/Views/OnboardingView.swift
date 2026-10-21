import SwiftUI

/// The first-launch checklist: what is set up, what is not, and one tap to fix each. Also reachable later from Help.
struct OnboardingView: View {
    let model: AppModel
    let finish: () -> Void
    @State private var scanning = false
    @State private var busy: OnboardingFix?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let items = model.checklist()
                List {
                    Section {
                        let done = items.allSatisfy(\.isDone)
                        Text(done ? "Everything is set up." : "Greenfield sets itself up. Tap each fix, top to bottom.").font(.headline)
                    }
                    ForEach(items) { item in
                        ChecklistRow(item: item, busy: busy == item.fix) { fix in
                            busy = fix
                            Task {
                                await model.perform(fix)
                                busy = nil
                            }
                        }
                    }
                    Section("Your computer") {
                        Button("Scan the computer's code", systemImage: "qrcode.viewfinder") { scanning = true }
                        Text("The installer on the computer shows a code. Scanning it adds the computer with no typing. Computers on your "
                             + "tailnet and network are also found by themselves.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Then try it") {
                        NavigationLink("Guided first dictation: say hello, then send it") { GuidedDictationView(model: model) }
                    }
                }
            }
            .navigationTitle("Get ready")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: finish) } }
            .sheet(isPresented: $scanning) { ScanComputerView(model: model) }
            .task {
                model.peers.startBonjour()
                await model.session.startListening()
                while !Task.isCancelled {
                    await model.health.refreshAll()
                    await model.peers.refresh()
                    model.peers.chooseTheOnlyComputer(health: model.health)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
}

struct ChecklistRow: View {
    let item: OnboardingItem
    let busy: Bool
    let fix: (OnboardingFix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(item.title, systemImage: icon).font(.headline).foregroundStyle(color)
            Text(item.detail).font(.callout)
            if case .working(let fraction?) = item.state { ProgressView(value: fraction) }
            if let action = item.fix, let label = item.fixLabel {
                Button {
                    fix(action)
                } label: {
                    if busy { ProgressView() } else { Text(label) }
                }
                .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch item.state {
        case .done: return "checkmark.circle.fill"
        case .working: return "arrow.triangle.2.circlepath"
        case .todo: return "circle"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .done: return .green
        case .working, .todo: return .orange
        case .blocked: return .red
        }
    }
}

/// "Say hello, then say send it" with a visible result and a plain pass or fail.
struct GuidedDictationView: View {
    let model: AppModel
    @State private var guided: GuidedDictation?

    var body: some View {
        let run = guided ?? GuidedDictation(flow: model.flow, delivery: model.delivery)
        List {
            Section {
                Text("Say hello, then say send it.").font(.title3.weight(.semibold))
                Text("This sends the word hello to \(run.computerName), as a real dictation, so you see the whole path work.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                switch run.phase {
                case .idle:
                    Button("Start", systemImage: "mic.fill") { begin(run) }.buttonStyle(.borderedProminent)
                case .listening:
                    Label("Listening. Say hello, then send it.", systemImage: "waveform").foregroundStyle(.red)
                    Button("Stop") { run.stopByHand() }
                case .checking:
                    Label("Checking…", systemImage: "hourglass")
                case .passed(let message):
                    Label("Pass", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green)
                    Text(message)
                    Button("Run it again") { begin(run) }
                case .failed(let message):
                    Label("Fail", systemImage: "xmark.octagon.fill").font(.title2.bold()).foregroundStyle(.red)
                    Text(message)
                    Button("Try again", systemImage: "arrow.clockwise") { begin(run) }.buttonStyle(.borderedProminent)
                }
                if let heard = run.heard { LabeledContent("Heard", value: heard) }
            }
        }
        .navigationTitle("First dictation")
        .onAppear { if guided == nil { guided = run } }
        .onDisappear { run.cancel() }
    }

    private func begin(_ run: GuidedDictation) {
        guided = run
        run.start()
    }
}

/// One line on the main screen: ready, or exactly one next step. Tap it to open the checklist.
struct ReadyLine: View {
    let model: AppModel
    @State private var showing = false

    var body: some View {
        let line = model.readiness()
        Button { showing = true } label: {
            Label(line.text, systemImage: line.ready ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                .font(.footnote.weight(.medium)).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered).tint(line.ready ? .green : .orange)
        .sheet(isPresented: $showing) { OnboardingView(model: model) { showing = false } }
        .accessibilityLabel("Am I ready? \(line.text)")
    }
}
