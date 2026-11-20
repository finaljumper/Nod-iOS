import XCTest
@testable import NodCore

final class MarkdownTests: XCTestCase {
    func testParagraphsHeadingsAndRules() {
        let blocks = MarkdownParser.blocks("# Today\n\nYou have **two** things.\nBoth are short.\n\n---\n\n### Later\nNothing.")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Today"),
            .paragraph("You have **two** things.\nBoth are short."),
            .rule,
            .heading(level: 3, text: "Later"),
            .paragraph("Nothing."),
        ])
    }

    func testListsKeepTheirMarkersAndNesting() {
        let blocks = MarkdownParser.blocks("Shopping:\n- milk\n- bread\n  - rye\n  with seeds\n\n1. first\n2) second")
        XCTAssertEqual(blocks, [
            .paragraph("Shopping:"),
            .list([
                .init(marker: "•", level: 0, text: "milk"),
                .init(marker: "•", level: 0, text: "bread"),
                .init(marker: "•", level: 1, text: "rye\nwith seeds"),
            ]),
            .list([.init(marker: "1.", level: 0, text: "first"), .init(marker: "2.", level: 0, text: "second")]),
        ])
    }

    func testCodeIsKeptAsWritten() {
        let blocks = MarkdownParser.blocks("Run this:\n```swift\nlet a = 1\n  # not a heading\n```\nDone.")
        XCTAssertEqual(blocks, [
            .paragraph("Run this:"),
            .code(language: "swift", text: "let a = 1\n  # not a heading"),
            .paragraph("Done."),
        ])
    }

    func testACodeBlockThatIsStillArrivingRunsToTheEnd() {
        XCTAssertEqual(MarkdownParser.blocks("```\nlet a ="), [.code(language: nil, text: "let a =")])
    }

    func testQuotesAndTables() {
        let blocks = MarkdownParser.blocks("> said once\n> said twice\n\n| Time | What |\n|---|:--|\n| 10:00 | Stand-up |\n| 12:30 |")
        XCTAssertEqual(blocks, [
            .quote("said once\nsaid twice"),
            .table(header: ["Time", "What"], rows: [["10:00", "Stand-up"], ["12:30", ""]]),
        ])
    }

    func testWhatOnlyLooksLikeMarkdownStaysText() {
        XCTAssertEqual(MarkdownParser.blocks("#hashtag and 3.14 and -5"), [.paragraph("#hashtag and 3.14 and -5")])
        XCTAssertEqual(MarkdownParser.blocks("| not a table"), [.paragraph("| not a table")])
        XCTAssertEqual(MarkdownParser.blocks(""), [])
    }

    func testKoreanAndRussianPassThrough() {
        XCTAssertEqual(MarkdownParser.blocks("## 오늘\n- 회의 두 개\n\nВсё **готово**."), [
            .heading(level: 2, text: "오늘"),
            .list([.init(marker: "•", level: 0, text: "회의 두 개")]),
            .paragraph("Всё **готово**."),
        ])
    }
}
