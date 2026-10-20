import SwiftUI

/// Every transcript and what became of it, with Resend and Copy.
struct OutboxView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.outbox.items.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "tray", description: Text("Transcripts you dictate are kept here."))
                }
                ForEach(model.outbox.items) { item in
                    OutboxRow(item: item, model: model)
                }
            }
            .navigationTitle("Outbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Send all unsent", systemImage: "arrow.up.circle") { Task { await model.delivery.resendAll() } }
                            .disabled(model.outbox.pending.isEmpty)
                        Button("Clear sent", systemImage: "trash", role: .destructive) { model.outbox.clearSent() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

struct OutboxRow: View {
    let item: OutboxItem
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).textSelection(.enabled)
            StatusLine(item: item)
            Text(item.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
            if item.status == .pending, !model.delivery.inFlight.contains(item.id) {
                Button("Resend", systemImage: "arrow.up.circle") { model.resend(item.id) }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button("Resend", systemImage: "arrow.up.circle") { model.resend(item.id) }
                .tint(.accentColor)
                .disabled(item.status == .sent)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { model.outbox.remove(item.id) }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
            Button("Resend", systemImage: "arrow.up.circle") { model.resend(item.id) }.disabled(item.status == .sent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Copy") { UIPasteboard.general.string = item.text }
            if item.status == .pending { Button("Resend") { model.resend(item.id) } }
        }
    }
}
