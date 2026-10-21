import KitHealth
import KitUI
import SwiftUI

/// ParrotKit's Diagnostics (recent events, filter, copy, clear) with the support log's Share logs button under it: the same redacted
/// file `make logs` pulls, events plus the outbox's ids and timings, never the dictated text, a key or a recording.
struct SupportDiagnosticsView: View {
    let log: EventLog
    let support: SupportLog
    @State private var shareURL: URL?

    var body: some View {
        DiagnosticsView(log: log)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if let shareURL {
                        ShareLink(item: shareURL, subject: Text("Support log"), message: Text("Events and outbox metadata only."),
                                  preview: SharePreview("Support log")) {
                            Label("Share logs", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label("The support log could not be saved on this phone.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    Text("The file has these events and the outbox's ids, states and timings. "
                         + "It never has what you dictated, a key or a recording.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .background(.bar)
            }
            .onAppear { shareURL = support.writeNow() }
    }
}
