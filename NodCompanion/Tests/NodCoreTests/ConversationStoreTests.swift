import XCTest
@testable import NodCore

final class ConversationStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appending(path: "nod-store-\(UUID().uuidString)/conversation.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testWhatNodsRecordHoldsComesBackAsItWas() {
        let store = ConversationStore(file: file)
        let asked = ChatMessage(role: .user, text: "What is on today?", attachments: [Attachment(name: "plan.pdf", mimeType: "application/pdf", byteCount: 12, data: Data([1, 2]))], status: .delivered, inputMode: .spoken, createdAt: Date(timeIntervalSince1970: 100))
        let answered = ChatMessage(role: .assistant, text: "**Two** things.", status: .delivered, createdAt: Date(timeIntervalSince1970: 101))
        let cut = ChatMessage(role: .assistant, text: "And then", status: .interrupted, createdAt: Date(timeIntervalSince1970: 102))
        let approved = ApprovalRequest(id: "a1", kind: .email, title: "Send the email", detail: "To Alex", state: .decided(.approved), requestedAt: Date(timeIntervalSince1970: 103))
        store.save([.message(asked), .message(answered), .message(cut), .approval(approved)])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 4)
        guard loaded.count == 4, case .message(let first) = loaded[0], case .approval(let last) = loaded[3] else { return XCTFail() }
        XCTAssertEqual(first.id, asked.id)
        XCTAssertEqual(first.inputMode, .spoken)
        XCTAssertEqual(first.attachments.first?.name, "plan.pdf")
        XCTAssertNil(first.attachments.first?.data, "the content of a file is not kept")
        XCTAssertEqual(loaded[1], .message(answered))
        XCTAssertEqual(loaded[2], .message(cut))
        XCTAssertEqual(last, approved)
    }

    func testWhatIsOnlyTrueForTheMomentIsNotKept() {
        let store = ConversationStore(file: file)
        store.save([
            .message(ChatMessage(role: .user, text: "on its way", status: .sending)),
            .message(ChatMessage(role: .user, text: "never arrived", status: .failed("offline"))),
            .message(ChatMessage(role: .assistant, text: "still arriv", status: .streaming)),
            .tool(ToolActivity(id: "t1", name: "calendar")),
            .approval(ApprovalRequest(id: "a1", kind: .purchase, title: "Buy", detail: "", state: .pending)),
            .approval(ApprovalRequest(id: "a2", kind: .purchase, title: "Buy", detail: "", state: .expired)),
        ])
        XCTAssertEqual(store.load().map(\.id), ["approval-a2"])
    }

    func testOnlyTheNewestEntriesAreKeptAndTheFileCanBeRemoved() {
        var store = ConversationStore(file: file)
        store.limit = 3
        store.save((1...5).map { .message(ChatMessage(role: .assistant, text: "\($0)", status: .delivered)) })
        let texts = store.load().compactMap { item -> String? in
            if case .message(let message) = item { return message.text } else { return nil }
        }
        XCTAssertEqual(texts, ["3", "4", "5"])
        store.remove()
        XCTAssertTrue(store.load().isEmpty)
    }
}
