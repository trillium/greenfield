import KitUI
import SwiftUI

/// The chosen Mac with its reachability dot; a menu switches between Macs.
struct TargetPicker: View {
    let model: AppModel
    /// The word before the chosen computer's name: "To:" where text is sent, "Computer:" where a tool acts on it.
    var prefix = "To:"
    /// Said when no computer has been added yet.
    var emptyNote = "Add a computer in the Computers tab to send your words somewhere."

    var body: some View {
        let targets = model.targets
        if targets.targets.isEmpty {
            Label(emptyNote, systemImage: "desktopcomputer")
                .font(.footnote).foregroundStyle(KitTokens.Text.secondary).multilineTextAlignment(.leading)
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
                        Text("\(prefix) \(selected.name)").font(.headline)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                    Spacer()
                }
            }
            .accessibilityLabel("Active computer")
            .accessibilityValue(targets.selected?.name ?? "")
            // What is written on the control is its first word too, so "Tap Computer" works as well as "Tap Active computer".
            .accessibilityInputLabels(["Active computer", String(prefix.dropLast(prefix.hasSuffix(":") ? 1 : 0))])
            .accessibilityHint("Opens a menu to choose another computer")
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
