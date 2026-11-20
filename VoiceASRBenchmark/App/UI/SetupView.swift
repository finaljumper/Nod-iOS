import ASRBenchCore
import SwiftUI

/// Device information, what each engine supports here, and the one step that uses the network.
struct SetupView: View {
    @Environment(BenchmarkViewModel.self) private var model

    var body: some View {
        List {
            Section("Device") {
                MetricRow(label: "Model", value: model.environment.deviceModel)
                MetricRow(label: "System", value: "\(model.environment.operatingSystem) \(model.environment.osVersion)")
                MetricRow(label: "Cores", value: "\(model.environment.processorCount)")
                MetricRow(label: "Memory", value: Format.megabytes(model.environment.physicalMemoryBytes))
                if model.environment.isDebugBuild {
                    Text("This is a Debug build. Use a Release build for measurements.").font(.footnote).foregroundStyle(.orange)
                }
                if model.environment.isSimulator {
                    Text("The Simulator does not represent device performance, and Apple's speech models may be unavailable in it.").font(.footnote).foregroundStyle(.orange)
                }
            }

            Section {
                Button(model.isPreparing ? "Downloading…" : "Download models and speech assets") {
                    Task { await model.downloadModels() }
                }
                .disabled(model.isPreparing || model.isRunning)
                if model.isPreparing {
                    ProgressView(value: model.setupProgress)
                }
                if !model.setupMessage.isEmpty {
                    Text(model.setupMessage).font(.footnote)
                }
                Button("Refresh status") { Task { await model.refreshEngineStatus() } }
                    .disabled(model.isPreparing || model.isRunning)
            } header: {
                Text("Setup")
            } footer: {
                Text("This is the only step that uses the network. It downloads the selected WhisperKit and Rumble-2-Flash models and installs Apple's speech assets for the languages Apple supports. Benchmarks never download anything and work offline afterwards.")
            }

            ForEach(model.engineDescriptors, id: \.id) { descriptor in
                Section(descriptor.displayName) {
                    ForEach(model.languageStatus.filter { $0.engineID == descriptor.id }) { status in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(status.language == "auto" ? "Auto-detect" : status.language).font(.callout)
                                Spacer()
                                availabilityLabel(status.availability)
                            }
                            if let reason = status.availability.reason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DisclosureGroup("Capabilities") {
                        CapabilityList(capabilities: descriptor.capabilities)
                    }
                    DisclosureGroup("Supported locales (\(model.supportedLocales[descriptor.id]?.count ?? 0))") {
                        Text((model.supportedLocales[descriptor.id] ?? []).joined(separator: ", "))
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Setup")
    }

    @ViewBuilder
    private func availabilityLabel(_ availability: EngineAvailability) -> some View {
        switch availability {
        case .available:
            Text("Ready").font(.caption.weight(.semibold)).foregroundStyle(.green)
        case .needsDownload:
            Text("Needs download").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .unavailable:
            Text("Unavailable").font(.caption.weight(.semibold)).foregroundStyle(.gray)
        }
    }
}
