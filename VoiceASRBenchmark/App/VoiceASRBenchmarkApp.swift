import SwiftUI

@main
struct VoiceASRBenchmarkApp: App {
    @State private var model = BenchmarkViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 760)
        #endif
    }
}
