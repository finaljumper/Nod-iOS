import SwiftUI

struct ContentView: View {
    @Environment(BenchmarkViewModel.self) private var model

    var body: some View {
        TabView {
            NavigationStack { BenchmarkView() }
                .tabItem { Label("Benchmark", systemImage: "stopwatch") }
            NavigationStack { ResultsView() }
                .tabItem { Label("Results", systemImage: "chart.bar") }
            NavigationStack { SetupView() }
                .tabItem { Label("Setup", systemImage: "arrow.down.circle") }
        }
    }
}
