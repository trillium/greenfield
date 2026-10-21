import SwiftUI

/// Recent events (sounds heard, rules fired, dictation, sends, microphone) so what the app did can be read without a cable.
struct DiagnosticsView: View {
    let log: EventLog
    @State private var category: EventLog.Category?

    private var shown: [EventLog.Entry] { log.entries.filter { category == nil || $0.category == category } }

    var body: some View {
        List {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink("Share the log", item: log.export())
                    Button("Copy the log", systemImage: "doc.on.doc") { UIPasteboard.general.string = log.export() }
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
