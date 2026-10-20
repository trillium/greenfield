import SwiftUI

/// The main screen: the state the flow is in, the last sound heard, the text box, and the tap-to-start, tap-to-stop button.
struct DictateView: View {
    let model: AppModel

    var body: some View {
        let session = model.session
        let flow = model.flow
        ScrollView {
            VStack(spacing: 16) {
                TargetPicker(model: model)
                ModelStatusLine(state: session.model)
                StateBanner(flow: flow)
                LastSoundLine(sound: flow.lastSound)
                TextBox(flow: flow)
                statusText(session)
                DictationButton(enabled: session.canHold, active: session.isHolding, busy: session.transcribing > 0,
                                tap: { flow.toggleDictation() })
                    .scaleEffect(0.7)
                    .frame(height: 140)
                if let item = model.outbox.items.first { QueuedLine(item: item, model: model) }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await model.health.refreshAll() }
    }

    @ViewBuilder
    private func statusText(_ session: DictationSession) -> some View {
        VStack(spacing: 4) {
            Text(headline(session)).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            if let detail = detail(session) {
                Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if session.micDenied || retryable(session) {
                Button("Try the microphone again") { Task { await session.retryMicrophone() } }.buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func retryable(_ session: DictationSession) -> Bool {
        switch session.listen.status {
        case .gaveUp, .interrupted: return true
        case .off, .listening, .backgrounded: return false
        }
    }

    private func headline(_ session: DictationSession) -> String {
        if case .failed = session.model { return "The speech model could not load" }
        if session.micDenied { return "Microphone access is off" }
        if session.isHolding { return "Listening…" }
        if session.transcribing > 0 { return "Transcribing…" }
        switch session.listen.status {
        case .interrupted: return "The microphone was interrupted"
        case .gaveUp: return "The microphone is unavailable"
        case .off, .backgrounded: return "Starting the microphone…"
        case .listening: return "Microphone ready"
        }
    }

    private func detail(_ session: DictationSession) -> String? {
        if case .failed(let message) = session.model { return message }
        if session.micDenied { return "Turn it on in Settings > Greenfield > Microphone." }
        switch session.notice {
        case .nothingHeard: return "Nothing was heard."
        case .failed(let message): return message
        case .none: break
        }
        switch session.listen.status {
        case .interrupted(let reason), .gaveUp(let reason): return reason
        case .off, .listening, .backgrounded: return nil
        }
    }
}

/// "Speech model ready", "Loading the speech model (already on this phone)" or "Downloading the speech model 42%".
struct ModelStatusLine: View {
    let state: DictationSession.ModelState

    var body: some View {
        VStack(spacing: 4) {
            Label(text, systemImage: icon).font(.footnote.weight(.medium)).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .downloading(let fraction) = state { ProgressView(value: fraction) }
            if case .downloading = state {
                Text("One time only: about 0.5 GB, kept on this phone. App updates keep it.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func text(for state: DictationSession.ModelState) -> String {
        switch state {
        case .notLoaded: return "Speech model: starting"
        case .downloading(let fraction): return "Downloading the speech model \(Int((fraction * 100).rounded()))%"
        case .loading: return "Loading the speech model (already on this phone)"
        case .ready: return "Speech model ready"
        case .failed: return "Speech model failed to load"
        }
    }

    private var text: String { Self.text(for: state) }

    private var icon: String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle"
        case .notLoaded, .loading: return "hourglass"
        }
    }

    private var color: Color {
        switch state {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

/// The flow state, big, and what the next sound will do.
struct StateBanner: View {
    let flow: FlowController

    var body: some View {
        VStack(spacing: 4) {
            Text(flow.state.title.uppercased())
                .font(.title2.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(color, in: RoundedRectangle(cornerRadius: 12))
            Text(flow.hint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .sensoryFeedback(.impact, trigger: flow.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("State \(flow.state.title). \(flow.hint)")
    }

    private var color: Color {
        switch flow.state {
        case .idle: return .gray
        case .dictating: return .red
        case .review: return .orange
        }
    }
}

struct LastSoundLine: View {
    let sound: FlowController.HeardSound?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let sound {
                let ago = max(0, Int(context.date.timeIntervalSince(sound.heardAt)))
                let percent = Int((sound.event.probability * 100).rounded())
                Label("Last sound: \(sound.event.pattern) (\(percent)%), \(ago) s ago", systemImage: "ear")
                    .font(.footnote.monospacedDigit())
            } else {
                Label("No sound recognised yet", systemImage: "ear").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dictated text lands here; Submit sends it to the active Mac.
struct TextBox: View {
    @Bindable var flow: FlowController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $flow.text)
                .frame(minHeight: 110)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if flow.text.isEmpty {
                        Text("Dictated text appears here").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Dictated text")
            HStack {
                Button("Clear", systemImage: "xmark.circle") { flow.text = "" }.disabled(flow.text.isEmpty)
                Spacer()
                Button("Submit", systemImage: "paperplane.fill") { flow.submit() }
                    .buttonStyle(.borderedProminent).disabled(!flow.canSubmit)
            }
        }
    }
}

/// The microphone button: tap to start dictation, tap to stop. Same state as the sounds.
struct DictationButton: View {
    let enabled: Bool
    let active: Bool
    let busy: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle().fill(active ? Color.red : Color.accentColor).opacity(enabled || active ? 1 : 0.35)
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                if busy && !active { ProgressView().tint(.white).offset(y: 70) }
            }
            .frame(width: 180, height: 180)
            .scaleEffect(active ? 1.06 : 1)
            .animation(.spring(duration: 0.2), value: active)
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !active)
        .sensoryFeedback(.impact, trigger: active)
        .accessibilityLabel(active ? "Stop dictation" : "Start dictation")
        .accessibilityHint("Tap to \(active ? "stop and write the text into the box" : "start recording")")
    }
}

/// The newest outbox entry: "Sent to MacBook in 12 ms", or why it is still queued.
struct QueuedLine: View {
    let item: OutboxItem
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last submitted").font(.caption).foregroundStyle(.secondary)
            Text(item.text).font(.callout).lineLimit(3)
            StatusLine(item: item)
            if item.status == .pending, !model.delivery.inFlight.contains(item.id) {
                Button("Send again") { model.resend(item.id) }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// "Sent to MacBook in 12 ms", "Sending…" or the reason it is still queued.
struct StatusLine: View {
    let item: OutboxItem

    var body: some View {
        switch item.status {
        case .sent:
            Label(sentText, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
        case .pending:
            if let error = item.lastError {
                Label("Queued: \(error)", systemImage: "tray.full.fill").font(.footnote).foregroundStyle(.orange)
            } else {
                Label("Sending…", systemImage: "arrow.up.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var sentText: String {
        var text = "Sent to \(item.targetName ?? "the Mac")"
        if let network = item.networkMs { text += " in \(network) ms" }
        return text
    }
}
