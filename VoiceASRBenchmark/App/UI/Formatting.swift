import ASRBenchCore
import SwiftUI

enum Format {
    static let dash = "—"

    static func percent(_ value: Double?) -> String {
        guard let value else { return dash }
        return String(format: "%.1f%%", value * 100)
    }

    static func seconds(_ value: Double?) -> String {
        guard let value else { return dash }
        return value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.2f s", value)
    }

    static func factor(_ value: Double?) -> String {
        guard let value else { return dash }
        return String(format: "%.3f", value)
    }

    static func megabytes(_ bytes: Double?) -> String {
        guard let bytes else { return dash }
        return String(format: "%.0f MB", bytes / 1_048_576)
    }

    static func megabytes(_ bytes: UInt64?) -> String {
        // Not `map(Double.init)`: that resolves to `Double(bitPattern:)` and yields nonsense.
        megabytes(bytes.map { Double($0) })
    }

    static func medianAndP95(_ distribution: Distribution?, _ format: (Double?) -> String = Format.seconds) -> String {
        guard let distribution else { return dash }
        return "\(format(distribution.median)) / \(format(distribution.p95))"
    }
}

extension RunStatus {
    var color: Color {
        switch self {
        case .success: return .green
        case .unavailable: return .gray
        case .failed: return .red
        case .skipped: return .orange
        case .cancelled: return .orange
        }
    }

    var label: String {
        switch self {
        case .success: return "OK"
        case .unavailable: return "Unavailable"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        }
    }
}

extension CapabilitySupport.Level {
    var label: String {
        switch self {
        case .native: return "Native"
        case .simulated: return "Simulated"
        case .unsupported: return "Unsupported"
        }
    }

    var color: Color {
        switch self {
        case .native: return .green
        case .simulated: return .orange
        case .unsupported: return .gray
        }
    }
}

/// A label and a value on one line.
struct MetricRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
