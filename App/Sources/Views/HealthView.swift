import SwiftUI

/// Checks everything the app depends on and says, in plain words, what is wrong and how to fix it.
struct HealthView: View {
    let model: AppModel
    @State private var items: [HealthItem] = []
    @State private var checking = false

    var body: some View {
        List {
            Section {
                Label(HealthReport.summary(items), systemImage: icon(for: items.map(\.level).max() ?? .ok))
                    .font(.headline).foregroundStyle(color(for: items.map(\.level).max() ?? .ok))
                Button("Check again", systemImage: "arrow.clockwise") { Task { await check() } }.disabled(checking)
            }
            ForEach(items) { HealthRow(item: $0) }
        }
        .navigationTitle("Health")
        .task { await check() }
    }

    private func check() async {
        checking = true
        items = model.healthReport()
        await model.health.refreshAll()
        items = model.healthReport()
        checking = false
    }
}

struct HealthRow: View {
    let item: HealthItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.title, systemImage: icon(for: item.level)).font(.headline).foregroundStyle(color(for: item.level))
            Text(item.detail).font(.callout)
            if let fix = item.fix {
                Label(fix, systemImage: "wrench.and.screwdriver").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

func icon(for level: HealthItem.Level) -> String {
    switch level {
    case .ok: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.circle.fill"
    case .problem: return "xmark.octagon.fill"
    }
}

func color(for level: HealthItem.Level) -> Color {
    switch level {
    case .ok: return .green
    case .warning: return .orange
    case .problem: return .red
    }
}

/// A line on the Dictate screen that appears only when something needs fixing, and opens the Health screen.
struct HealthBanner: View {
    let model: AppModel
    @State private var showing = false

    var body: some View {
        let items = model.healthReport()
        // The microphone and model are still starting for the first second; only real problems interrupt.
        let problems = items.filter { $0.level == .problem }
        if let first = problems.first {
            Button { showing = true } label: {
                Label("\(first.title): \(first.detail)", systemImage: "xmark.octagon.fill")
                    .font(.footnote).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).tint(.red)
            .sheet(isPresented: $showing) { NavigationStack { HealthView(model: model) } }
        }
    }
}
