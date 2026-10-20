import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Dictation")
                .font(.title2.bold())
            Text(BuildInfo().display)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
