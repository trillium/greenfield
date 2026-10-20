import SwiftUI

/// The main screen: pick a Mac, hold the button, speak, let go.
struct DictateView: View {
    let model: AppModel

    var body: some View {
        let session = model.session
        VStack(spacing: 20) {
            TargetPicker(model: model)
            Spacer(minLength: 0)
            statusText(session)
            HoldButton(enabled: session.canHold, active: session.isHolding, busy: session.transcribing > 0,
                       press: { session.beginHold() }, release: { session.endHold() })
            Spacer(minLength: 0)
            LastTranscript(model: model)
        }
        .padding()
        .task { await model.health.refreshAll() }
    }

    @ViewBuilder
    private func statusText(_ session: DictationSession) -> some View {
        VStack(spacing: 4) {
            Text(headline(session)).font(.headline).multilineTextAlignment(.center)
            if let detail = detail(session) {
                Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if case .loading(let fraction) = session.model { ProgressView(value: fraction).padding(.horizontal, 40) }
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
        if case .loading = session.model { return "Getting the speech model ready" }
        if case .failed = session.model { return "The speech model could not load" }
        if session.micDenied { return "Microphone access is off" }
        if session.isHolding { return "Listening…" }
        if session.transcribing > 0 { return "Transcribing…" }
        switch session.listen.status {
        case .interrupted: return "The microphone was interrupted"
        case .gaveUp: return "The microphone is unavailable"
        case .off, .backgrounded: return "Starting the microphone…"
        case .listening: return "Hold the button and speak"
        }
    }

    private func detail(_ session: DictationSession) -> String? {
        switch session.model {
        case .loading: return "This happens once, and downloads about 0.5 GB. It stays on the phone."
        case .failed(let message): return message
        case .notLoaded, .ready: break
        }
        if session.micDenied { return "Turn it on in Settings > Dictation > Microphone." }
        switch session.notice {
        case .nothingHeard: return "Nothing was heard. Hold the button while you speak."
        case .failed(let message): return message
        case .none: break
        }
        switch session.listen.status {
        case .interrupted(let reason), .gaveUp(let reason): return reason
        case .off, .listening, .backgrounded: return nil
        }
    }
}

struct HoldButton: View {
    let enabled: Bool
    let active: Bool
    let busy: Bool
    let press: () -> Void
    let release: () -> Void
    @State private var down = false

    var body: some View {
        ZStack {
            Circle().fill(active ? Color.red : Color.accentColor).opacity(enabled || active ? 1 : 0.35)
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Image(systemName: active ? "waveform" : "mic.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: active)
            if busy && !active { ProgressView().tint(.white).offset(y: 70) }
        }
        .frame(width: 180, height: 180)
        .scaleEffect(active ? 1.08 : 1)
        .animation(.spring(duration: 0.2), value: active)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !down else { return }
                down = true
                press()
            }
            .onEnded { _ in
                down = false
                release()
            })
        .sensoryFeedback(.impact, trigger: active)
        .accessibilityLabel("Hold to talk")
        .accessibilityHint("Press and hold while you speak, then let go to send the text")
        .accessibilityAddTraits(.isButton)
    }
}

struct LastTranscript: View {
    let model: AppModel

    var body: some View {
        if let item = model.outbox.items.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text).font(.body).textSelection(.enabled)
                StatusLine(item: item)
                if item.status == .pending, !model.delivery.inFlight.contains(item.id) {
                    Button("Send again") { model.resend(item.id) }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        } else {
            Text("Your words appear here.").font(.footnote).foregroundStyle(.secondary).padding()
        }
    }
}

/// "Sent to MacBook in 12 ms", "Sending…" or the reason it failed.
struct StatusLine: View {
    let item: OutboxItem

    var body: some View {
        switch item.status {
        case .sent:
            Label(sentText, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
        case .pending:
            if let error = item.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
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
