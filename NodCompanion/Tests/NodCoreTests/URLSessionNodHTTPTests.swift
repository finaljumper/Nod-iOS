import Network
import XCTest
@testable import NodCore

/// The real network layer against a small HTTP server on this machine.
final class URLSessionNodHTTPTests: XCTestCase {
    /// Answers every connection with what `respond` returns for the request's first line: a
    /// head and body parts that are sent 30 ms apart, after which the connection is closed.
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _heads: [String] = []
        var heads: [String] { lock.withLock { _heads } }

        init(respond: @escaping @Sendable (String) -> [String]) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                    let head = String(decoding: data ?? Data(), as: UTF8.self)
                    self?.record(head)
                    let parts = respond(head.components(separatedBy: "\r\n").first ?? "")
                    Self.send(parts[...], on: connection)
                }
            }
        }

        private func record(_ head: String) {
            lock.withLock { _heads.append(head) }
        }

        private static func send(_ parts: ArraySlice<String>, on connection: NWConnection) {
            guard let part = parts.first else { return connection.cancel() }
            connection.send(content: Data(part.utf8), completion: .contentProcessed { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
                    send(parts.dropFirst(), on: connection)
                }
            })
        }

        func start() async throws -> URL {
            let ready = expectationStream()
            listener.stateUpdateHandler = { state in if case .ready = state { ready.continuation.yield() } }
            listener.start(queue: .global())
            for await _ in ready.stream { break }
            return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
        }

        private func expectationStream() -> (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation) {
            AsyncStream<Void>.makeStream()
        }
    }

    func testAnEventStreamArrivesPieceByPieceWithItsEmptyLines() async throws {
        let server = try Server { _ in
            [
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                "data: {\"type\":\"refresh\"}\n\n",
                ": keepalive\n\n",
                "data: {\"type\":\"delta\",\"threadId\":\"t\",\"turnId\":\"u\",",
                "\"text\":\"안녕 привет\",\"done\":false}\n\n",
            ]
        }
        let address = try await server.start()
        defer { server.listener.cancel() }

        let client = NodClient(baseURL: address, key: "test-key-that-is-not-a-real-one", http: URLSessionNodHTTP())
        var events: [NodAPI.Event] = []
        for try await event in client.events(account: "owner 1") { events.append(event) }

        XCTAssertEqual(events, [.refresh, .delta(NodAPI.Delta(threadId: "t", turnId: "u", text: "안녕 привет", done: false))])
        let head = try XCTUnwrap(server.heads.first)
        XCTAssertTrue(head.hasPrefix("GET /api/events?account=owner%201 HTTP/1.1"), head)
        XCTAssertTrue(head.contains("Authorization: Bearer test-key-that-is-not-a-real-one"))
        XCTAssertTrue(head.contains("Accept: text/event-stream"))
        XCTAssertFalse(head.contains("Origin:"), "no browser origin is invented")
        XCTAssertFalse(head.contains("Cookie:"))
    }

    func testARedirectIsNotFollowedSoTheKeyGoesNowhereElse() async throws {
        let server = try Server { line in
            line.contains("/api/session")
                ? ["HTTP/1.1 302 Found\r\nLocation: /somewhere-else\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"]
                : ["HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"]
        }
        let address = try await server.start()
        defer { server.listener.cancel() }

        let client = NodClient(baseURL: address, key: "test-key-that-is-not-a-real-one", http: URLSessionNodHTTP())
        do {
            _ = try await client.session()
            XCTFail("the redirect was followed")
        } catch {
            XCTAssertEqual(error as? NodError, .redirected)
        }
        XCTAssertEqual(server.heads.count, 1, "nothing was requested from the redirect's target")
    }

    func testAnErrorAnswerIsReadFromNodsBody() async throws {
        let body = #"{"error":"Enter your server authentication token."}"#
        let server = try Server { _ in
            ["HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"]
        }
        let address = try await server.start()
        defer { server.listener.cancel() }

        let check = await NodConnectionCheck.address(address)
        XCTAssertNoThrow(try check.get(), "an address that asks for the key is Nod")
        let refused = await NodConnectionCheck.key("wrong", at: address)
        XCTAssertEqual(refused.failure, .unauthorized("Enter your server authentication token."))
    }

    func testAnAddressNothingListensOnIsUnreachable() async {
        let check = await NodConnectionCheck.address(URL(string: "http://127.0.0.1:9")!)
        guard case .failure(.unreachable) = check else { return XCTFail("\(check)") }
    }
}
