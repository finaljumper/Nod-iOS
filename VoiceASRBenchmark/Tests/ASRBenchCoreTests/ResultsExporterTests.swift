import XCTest
@testable import ASRBenchCore

final class ResultsExporterTests: XCTestCase {
    private func sampleRun() async throws -> BenchmarkRun {
        let recordings = [
            TestDataset.recording("en-1", ["en"], "He said \"turn it on\", then left"),
            TestDataset.recording("ko-1", ["ko"], "오늘 날씨 어때"),
        ]
        let data = try TestDataset(recordings)
        defer { data.cleanUp() }
        let full = MockEngine(id: "full", languages: ["en", "ko"])
        let fingerprints = data.fingerprints
        full.respond = { fingerprint, _ in fingerprint == fingerprints["ko-1"] ? "오늘 날씨 어대" : "he said turn it on,\nthen left" }
        let partial = MockEngine(id: "english-only", languages: ["en"])
        partial.respond = { _, _ in "he said turn it on then left" }
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let dependencies = BenchmarkRunner.Dependencies(thermalProbe: { .nominal }, sleep: { _ in })
        return await BenchmarkRunner(dependencies: dependencies).run(dataset: data.dataset, engines: [full, partial], configuration: config)
    }

    /// Minimal RFC 4180 parser for checking the export.
    private func parse(_ csv: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        let characters = Array(csv)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field); field = ""
            } else if character == "\r\n" || character == "\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        return rows
    }

    func testJSONRoundTripIsLossless() async throws {
        let run = try await sampleRun()
        let data = try ResultsExporter.json(run)
        let decoded = try ResultsExporter.decodeJSON(data)
        XCTAssertEqual(decoded.records.count, run.records.count)
        XCTAssertEqual(decoded.records.map(\.hypothesis), run.records.map(\.hypothesis))
        XCTAssertEqual(decoded.records.map(\.accuracy), run.records.map(\.accuracy))
        XCTAssertEqual(decoded.summaries, run.summaries)
        XCTAssertEqual(decoded.configuration, run.configuration)
        XCTAssertEqual(decoded.environment, run.environment)
        XCTAssertEqual(decoded.engines, run.engines)
        XCTAssertEqual(decoded.recordings, run.recordings)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("오늘 날씨 어때"), "Korean is written as text, not escaped")
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
    }

    func testRunsCSVHasOneRowPerRecordAndQuotesCorrectly() async throws {
        let run = try await sampleRun()
        let rows = parse(ResultsExporter.runsCSV(run))
        XCTAssertEqual(rows.count, run.records.count + 1)
        let header = rows[0]
        XCTAssertTrue(rows.allSatisfy { $0.count == header.count })
        func column(_ name: String) -> Int { header.firstIndex(of: name)! }

        let english = rows.first { $0[column("engine_id")] == "full" && $0[column("recording_id")] == "en-1" }!
        XCTAssertEqual(english[column("reference")], "He said \"turn it on\", then left")
        XCTAssertEqual(english[column("hypothesis")], "he said turn it on,\nthen left")
        XCTAssertEqual(english[column("wer_relaxed")], "0")
        XCTAssertEqual(english[column("status")], "success")
        XCTAssertFalse(english[column("inference_s")].isEmpty)
        XCTAssertTrue(english[column("time_to_final_s")].isEmpty, "batch runs have no streaming latencies")

        let korean = rows.first { $0[column("engine_id")] == "full" && $0[column("recording_id")] == "ko-1" }!
        XCTAssertEqual(korean[column("hypothesis")], "오늘 날씨 어대")
        XCTAssertEqual(Double(korean[column("cer_relaxed")])!, 1.0 / 6.0, accuracy: 1e-5)

        let unavailable = rows.first { $0[column("status")] == "unavailable" }!
        XCTAssertEqual(unavailable[column("engine_id")], "english-only")
        XCTAssertEqual(unavailable[column("status_reason")], "english-only does not support ko.")
        XCTAssertTrue(unavailable[column("wer_relaxed")].isEmpty, "unavailable runs carry no error rate")
    }

    func testSummaryCSV() async throws {
        let run = try await sampleRun()
        let rows = parse(ResultsExporter.summaryCSV(run))
        XCTAssertEqual(rows.count, run.summaries.count + 1)
        let header = rows[0]
        XCTAssertTrue(rows.allSatisfy { $0.count == header.count })
        func column(_ name: String) -> Int { header.firstIndex(of: name)! }
        let korean = rows.first { $0[column("engine_id")] == "english-only" && $0[column("group_kind")] == "language" && $0[column("group_value")] == "ko" }!
        XCTAssertEqual(korean[column("unavailable_runs")], "1")
        XCTAssertEqual(korean[column("measured_runs")], "0")
        XCTAssertTrue(korean[column("wer_relaxed")].isEmpty)
        let all = rows.first { $0[column("engine_id")] == "full" && $0[column("group_kind")] == "all" }!
        XCTAssertEqual(all[column("measured_runs")], "4")
        XCTAssertFalse(all[column("inference_median_s")].isEmpty)
        XCTAssertFalse(all[column("inference_p95_s")].isEmpty)
    }

    func testEscaping() {
        XCTAssertEqual(ResultsExporter.escape("plain"), "plain")
        XCTAssertEqual(ResultsExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(ResultsExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ResultsExporter.escape("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(ResultsExporter.number(nil), "")
        XCTAssertEqual(ResultsExporter.number(.infinity), "")
        XCTAssertEqual(ResultsExporter.number(0.125), "0.125")
    }

    /// Regression: `UInt64?.map(Double.init)` picks `Double(bitPattern:)`, which turned every
    /// memory figure into roughly zero.
    func testMemoryIsExportedInMegabytes() async throws {
        XCTAssertEqual(ResultsExporter.megabytes(UInt64(3 * 1_048_576)), "3.0")
        XCTAssertEqual(ResultsExporter.megabytes(UInt64?.none), "")

        let run = try await sampleRun()
        let runs = parse(ResultsExporter.runsCSV(run))
        let peakColumn = runs[0].firstIndex(of: "peak_memory_mb")!
        let measured = runs.dropFirst().first { $0[runs[0].firstIndex(of: "status")!] == "success" }!
        // The test process itself uses far more than a megabyte.
        XCTAssertGreaterThan(Double(measured[peakColumn])!, 1)

        let summary = parse(ResultsExporter.summaryCSV(run))
        func column(_ name: String) -> Int { summary[0].firstIndex(of: name)! }
        let all = summary.first { $0[column("engine_id")] == "full" && $0[column("group_kind")] == "all" }!
        XCTAssertGreaterThan(Double(all[column("peak_memory_median_mb")])!, 1)
        XCTAssertGreaterThan(Double(all[column("peak_memory_max_mb")])!, 1)
    }

    func testFileStem() async throws {
        var run = try await sampleRun()
        run.startedAt = Date(timeIntervalSince1970: 1_795_000_000)
        run.environment.deviceModel = "Mac16,10"
        XCTAssertEqual(ResultsExporter.fileStem(for: run), "asr-benchmark-batch-Mac16,10-20261118-110640")
    }
}
