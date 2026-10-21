import SwiftUI

/// The chosen Mac with its reachability dot; a menu switches between Macs.
struct TargetPicker: View {
    let model: AppModel

    var body: some View {
        let targets = model.targets
        if targets.targets.isEmpty {
            Label("Add a computer in the Computers tab to send your words somewhere.", systemImage: "desktopcomputer")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Menu {
                ForEach(targets.targets) { target in
                    Button {
                        targets.select(target.id)
                    } label: {
                        Label(target.name, systemImage: target.id == targets.selectedID ? "checkmark" : "desktopcomputer")
                    }
                }
            } label: {
                HStack {
                    if let selected = targets.selected {
                        HealthDot(state: model.health.state(for: selected))
                        Text("To: \(selected.name)").font(.headline)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                    Spacer()
                }
            }
            .accessibilityLabel("Active computer")
        }
    }
}

struct HealthDot: View {
    let state: TargetHealth.State

    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .accessibilityLabel(state.summary)
    }

    private var color: Color {
        switch state {
        case .ready: return .green
        case .notice, .wrongKey, .keyNotSetOnMac, .incompatible: return .orange
        case .unreachable: return .red
        case .unknown, .checking: return .gray
        }
    }
}
