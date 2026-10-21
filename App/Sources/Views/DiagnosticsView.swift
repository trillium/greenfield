import SwiftUI

/// Recent events (sounds heard, rules fired, dictation, sends, microphone) so what the app did can be read without a cable.
struct DiagnosticsView: View {
    let log: EventLog
    let support: SupportLog
    @State private var category: EventLog.Category?
    /// The redacted support log, written when this screen opens; nil when it could not be saved.
    @State private var shareURL: URL?

    private var shown: [EventLog.Entry] { log.entries.filter { category == nil || $0.category == category } }

    var body: some View {
        List {
            Section {
                if let shareURL {
                    ShareLink(item: shareURL, subject: Text("Support log"), message: Text("Events and outbox metadata only."),
                              preview: SharePreview("Support log")) {
                        Label("Share logs", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("The support log could not be saved on this phone.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                Text("The file has the events below and the outbox's ids, states and timings. "
                     + "It never has what you dictated, a key or a recording.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Show", selection: $category) {
                    Text("Everything").tag(EventLog.Category?.none)
                    ForEach(EventLog.Category.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
            Section("\(shown.count) events, newest first") {
                if shown.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(shown) { EventRow(entry: $0) }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { shareURL = support.writeNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy the log", systemImage: "doc.on.doc") { UIPasteboard.general.string = support.render() }
                    Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

struct EventRow: View {
    let entry: EventLog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.text).font(.callout)
            Text("\(entry.category.title), \(entry.date.formatted(date: .omitted, time: .complete))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
