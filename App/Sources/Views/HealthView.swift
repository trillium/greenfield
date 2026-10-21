import KitHealth
import KitUI
import SwiftUI

/// Checks everything the app depends on and says, in plain words, what is wrong and how to fix it. The list is the shared KitUI one; the
/// checks are this app's (`AppHealth`).
struct HealthView: View {
    let model: AppModel
    @State private var report = HealthReport(items: [])
    @State private var checking = false

    var body: some View {
        HealthListView(report: report, checking: checking) { Task { await check() } }
            .task { await check() }
    }

    private func check() async {
        checking = true
        report = model.healthReport()
        async let computers: Void = model.health.refreshAll()
        async let trainers: Void = model.trainers.refresh()
        _ = await (computers, trainers)
        report = model.healthReport()
        checking = false
    }
}
