import ParrotKit
import ParrotKitUI
import SwiftUI

/// The shared Levels screen, built over this app's detector. The model is made when the screen opens, so it always sees the sounds of the
/// model in use now.
struct LevelsScreen: View {
    @State private var model: LevelsModel

    init(flow: FlowController) {
        _model = State(initialValue: flow.levels.makeModel())
    }

    var body: some View {
        LevelsView(model: model)
    }
}
