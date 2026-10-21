import KitUI
import SwiftUI

/// The editable list of rules: sound (with count and time window) plus from-state → to-state and an action.
struct RulesView: View {
    let flow: FlowController
    @State private var rules: [SoundRule] = []
    @State private var confirmReset = false

    var body: some View {
        List {
            ForEach($rules) { $rule in
                NavigationLink {
                    RuleEditor(rule: $rule, sounds: flow.availableSounds)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.summary).font(.headline).foregroundStyle(rule.enabled ? .primary : .secondary)
                        Text(rule.action.title).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { rules.remove(atOffsets: $0) }
            .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            Section {
                Button("Add a rule", systemImage: "plus") {
                    rules.append(SoundRule(trigger: SoundTrigger(sound: flow.availableSounds.first ?? "tongue-click"), from: .idle,
                                           to: .dictating, action: .startDictation))
                }
                Button("Reset to defaults", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
            } footer: {
                Text("A rule fires when its sound is heard (the given number of times within the window) while the flow is in its "
                     + "from-state. Rules are checked top to bottom. Don't give two rules the same sound and state.")
            }
        }
        .navigationTitle("Rules")
        .toolbar { EditButton() }
        .confirmationDialog("Reset every rule to its default?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to defaults", role: .destructive) { rules = SoundRule.defaults }
            Button("Keep my rules", role: .cancel) { }
        } message: {
            Text("This replaces the \(rules.count) rules listed here with the factory defaults. It cannot be undone.")
        }
        .onAppear { rules = flow.rules }
        .onChange(of: rules) { _, new in flow.setRules(new) }
    }
}

struct RuleEditor: View {
    @Binding var rule: SoundRule
    let sounds: [String]

    var body: some View {
        Form {
            Section("When this sound is heard") {
                Picker("Sound", selection: $rule.trigger.sound) {
                    ForEach(sounds + (sounds.contains(rule.trigger.sound) ? [] : [rule.trigger.sound]), id: \.self) { Text($0).tag($0) }
                }
                Stepper("Times: \(rule.trigger.count)", value: $rule.trigger.count, in: 1...5)
                if rule.trigger.count > 1 {
                    Stepper("Within \(rule.trigger.withinSeconds.formatted(.number.precision(.fractionLength(1)))) s",
                            value: $rule.trigger.withinSeconds, in: 0.5...4, step: 0.5)
                }
            }
            Section("Move") {
                Picker("From", selection: $rule.from) { ForEach(FlowState.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("To", selection: $rule.to) { ForEach(FlowState.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Section("Do") {
                Picker("Action", selection: $rule.action) { ForEach(FlowAction.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            WordToggle(title: "Enabled", isOn: $rule.enabled)
        }
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
    }
}
