import KitAssist
import KitUI
import SwiftUI

/// The Assist tab: the kit's `AssistView` for the computer that is active in this app, with this app's computer picker, wording and
/// transports (`AssistWiring`). The status it reads is the one the Health screen reads, so both say the same thing about the computer.
struct AssistTabView: View {
    let model: AppModel
    @State private var cache = AssistTransportCache()

    private var selected: MacTarget? { model.targets.selected }

    var body: some View {
        NavigationStack {
            content
        }
        .assistStrings(AssistWiring.strings)
        .task(id: selected?.id) { await checkAgain() }
    }

    @ViewBuilder private var content: some View {
        let answer = selected.flatMap { model.health.answers[$0.id] }
        if let availability = AssistWiring.availability(selected: selected, answer: answer) {
            // The transports are made only when there is something to send them to; the id gives each computer its own tab state.
            let transports = availability.hasTools ? selected.flatMap { cache.transports(for: $0) } : nil
            AssistView(availability: availability, computerName: selected?.name ?? "", pointer: transports?.pointer,
                       windows: transports?.windows, checkAgain: { Task { await checkAgain() } }, computerPicker: { picker })
                .id(selected.map { "\($0.id)-\($0.address)" } ?? "none")
        } else {
            List {
                Section { picker }
                Section {
                    Label(AssistStrings.fill(AssistWiring.lookingTitle, DisplayText.clean(selected?.name ?? "")),
                          systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .navigationTitle(AssistWiring.strings.assistTitle)
        }
    }

    private var picker: some View {
        TargetPicker(model: model, prefix: "Computer:", emptyNote: "Add a computer in the Computers tab to use these tools on it.")
    }

    private func checkAgain() async {
        guard let target = selected else { return }
        await model.health.refresh(target)
    }
}
