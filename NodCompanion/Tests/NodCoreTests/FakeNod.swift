import Foundation
@testable import NodCore

/// A stand-in for a Nod server that answers the routes the app uses in the shapes Nod's source
/// gives them. It replaces the network, not Nod's behaviour: what a real Nod does and when is
/// scripted by each test.
final class FakeNod: NodHTTP, @unchecked Sendable {
    struct Call {
        var method: String
        var path: String
        var query: String?
        var authorization: String?
        var body: [String: Any]
    }

    static let key = "test-key-that-is-not-a-real-one"

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _messages: [[String: Any]] = []
    private var _turns: [[String: Any]] = []
    private var _uploads: [[String: Any]] = []
    private var eventOutputs: [AsyncThrowingStream<String, any Error>.Continuation] = []
    private var _threadID = UUID().uuidString.lowercased()
    /// Answers given once instead of the normal one, by path.
    private var overrides: [String: (status: Int, body: String, headers: [String: String])] = [:]
    private var _eventsRefused = false
    private var _eventsSilent = false

    var calls: [Call] { lock.withLock { _calls } }
    var threadID: String { lock.withLock { _threadID } }
    var userMessages: [[String: Any]] { lock.withLock { _messages.filter { $0["role"] as? String == "user" } } }
    var eventConnections: Int { lock.withLock { eventOutputs.count } }
    /// The files stored so far: id, name, mimeType, size.
    var uploads: [[String: Any]] { lock.withLock { _uploads } }

    func calls(to path: String, method: String = "GET") -> [Call] {
        calls.filter { $0.path == path && $0.method == method }
    }

    // MARK: Scripting

    func answerOnce(_ path: String, status: Int, body: String, headers: [String: String] = [:]) {
        lock.withLock { overrides[path] = (status, body, headers) }
    }

    func resetConversation() {
        lock.withLock {
            _threadID = UUID().uuidString.lowercased()
            _messages = []
            _turns = []
        }
    }

    @discardableResult
    func addMessage(role: String, text: String, turn: String? = nil, approval: [String: Any]? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        var message: [String: Any] = ["id": id, "role": role, "text": text, "turnId": turn ?? NSNull(), "createdAt": "2026-11-20T10:00:00.000Z", "attachments": []]
        if let approval { message["approval"] = approval }
        lock.withLock { _messages.append(message) }
        return id
    }

    func setTurn(_ id: String, status: String, error: String? = nil) {
        lock.withLock {
            if let index = _turns.firstIndex(where: { $0["id"] as? String == id }) {
                _turns[index]["status"] = status
                if let error { _turns[index]["error"] = error }
            } else {
                _turns.append(["id": id, "status": status, "source": "user", "createdAt": "2026-11-20T10:00:00.000Z"])
            }
        }
    }

    func setApproval(_ id: String, state: String) {
        lock.withLock {
            for index in _messages.indices {
                if var approval = _messages[index]["approval"] as? [String: Any], approval["id"] as? String == id {
                    approval["state"] = state
                    _messages[index]["approval"] = approval
                }
            }
        }
    }

    /// Sends one event to every open event stream.
    func emit(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        let outputs = lock.withLock { eventOutputs }
        for output in outputs {
            output.yield("data: " + String(decoding: data, as: UTF8.self))
            output.yield("")
        }
    }

    func refresh() { emit(["type": "refresh"]) }

    func delta(turn: String, _ text: String, stream: String? = nil, thread: String? = nil) {
        var event: [String: Any] = ["type": "delta", "threadId": thread ?? threadID, "turnId": turn, "text": text, "done": false]
        if let stream { event["streamId"] = stream }
        emit(event)
    }

    /// Stores the reply, ends the turn and says so, as Nod does.
    func finish(turn: String, reply: String?) {
        if let reply { addMessage(role: "assistant", text: reply, turn: turn) }
        setTurn(turn, status: "succeeded")
        refresh()
    }

    /// Breaks every open event stream, as a lost connection does.
    func dropEvents() {
        let outputs = lock.withLock {
            let outputs = eventOutputs
            eventOutputs = []
            return outputs
        }
        for output in outputs { output.finish(throwing: URLError(.networkConnectionLost)) }
    }

    func refuseEvents(_ refused: Bool) { lock.withLock { _eventsRefused = refused } }

    /// Opens event streams and sends nothing on them, as a proxy that holds the answer back does.
    func silenceEvents(_ silent: Bool) { lock.withLock { _eventsSilent = silent } }

    // MARK: NodHTTP

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = record(request)
        if let override = lock.withLock({ overrides.removeValue(forKey: call.path) }) {
            return (Data(override.body.utf8), response(request, override.status, override.headers))
        }
        guard call.authorization == "Bearer \(Self.key)" else {
            return json(request, 401, ["error": "Enter your server authentication token."])
        }
        switch (call.method, call.path) {
        case ("GET", "/api/health"):
            return json(request, 200, ["ok": true])
        case ("GET", "/api/session"):
            return json(request, 200, ["user": ["id": "owner-1", "name": "Ren", "email": NSNull(), "avatarUrl": NSNull()], "settings": NSNull(), "capabilities": [:] as [String: Any]])
        case ("GET", "/api/state"):
            let state: [String: Any] = lock.withLock {
                ["threadId": _threadID, "messages": _messages, "turns": _turns, "activity": [] as [Any], "configuration": ["llmReady": true]]
            }
            return json(request, 200, state)
        case ("POST", "/api/messages"):
            return postMessage(request, call.body)
        case ("POST", "/api/uploads"):
            return storeUpload(request)
        case ("POST", "/api/thread/stop"):
            lock.withLock {
                for index in _turns.indices where ["queued", "running", "waiting"].contains(_turns[index]["status"] as? String ?? "") {
                    _turns[index]["status"] = "cancelled"
                }
            }
            return json(request, 200, ["ok": true])
        default:
            return json(request, 404, ["error": "Not found."])
        }
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let call = record(request)
        let refused = lock.withLock { _eventsRefused }
        if refused { throw URLError(.cannotConnectToHost) }
        guard call.authorization == "Bearer \(Self.key)" else {
            let stream = AsyncThrowingStream<String, any Error> {
                $0.yield(#"{"error":"Enter your server authentication token."}"#)
                $0.finish()
            }
            return (response(request, 401, ["Content-Type": "application/json"]), stream)
        }
        let (stream, output) = AsyncThrowingStream<String, any Error>.makeStream()
        lock.withLock { eventOutputs.append(output) }
        if lock.withLock({ _eventsSilent }) { return (response(request, 200, ["Content-Type": "text/event-stream"]), stream) }
        // Nod greets every new stream with a refresh.
        output.yield(#"data: {"type":"refresh"}"#)
        output.yield("")
        output.yield(": keepalive")
        output.yield("")
        return (response(request, 200, ["Content-Type": "text/event-stream"]), stream)
    }

    // MARK: Plumbing

    /// Reads the one file of a multipart form, as Nod does.
    private func storeUpload(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let body = request.httpBody, let boundary = type.components(separatedBy: "boundary=").dropFirst().first,
              let headEnd = body.range(of: Data("\r\n\r\n".utf8)),
              let tail = body.range(of: Data("\r\n--\(boundary)--".utf8), options: .backwards)
        else { return json(request, 400, ["error": "Choose a file to upload."]) }
        let head = String(decoding: body[..<headEnd.lowerBound], as: UTF8.self)
        let content = body[headEnd.upperBound..<tail.lowerBound]
        guard head.contains("name=\"file\""), !content.isEmpty else {
            return json(request, 400, ["error": "Files must be between 1 byte and 90 MB."])
        }
        let name = head.components(separatedBy: "filename=\"").dropFirst().first?.components(separatedBy: "\"").first ?? "file"
        let mime = head.components(separatedBy: "Content-Type: ").dropFirst().first?.components(separatedBy: "\r\n").first ?? "application/octet-stream"
        let id = UUID().uuidString.lowercased()
        let artifact: [String: Any] = ["id": id, "name": name, "mimeType": mime, "size": content.count, "url": "/api/artifacts/\(id)"]
        lock.withLock { _uploads.append(artifact) }
        return json(request, 200, artifact)
    }

    private func postMessage(_ request: URLRequest, _ body: [String: Any]) -> (Data, HTTPURLResponse) {
        let allowed: Set = ["text", "threadId", "clientMessageId", "replyToMessageId", "approvalAnswer", "attachmentIds"]
        guard Set(body.keys).isSubset(of: allowed) else {
            // Nod's input schema is strict: an unknown field is refused.
            return json(request, 400, ["error": "Check the supplied values."])
        }
        guard body["threadId"] as? String == threadID else {
            return json(request, 409, ["error": "This conversation has been reset. Reload it before continuing."])
        }
        let text = body["text"] as? String ?? ""
        if let answer = body["approvalAnswer"] as? [String: Any] {
            let approvalID = answer["approvalId"] as? String ?? ""
            let replyTo = body["replyToMessageId"] as? String
            let open: Bool = lock.withLock {
                _messages.contains { message in
                    message["id"] as? String == replyTo
                        && (message["approval"] as? [String: Any])?["id"] as? String == approvalID
                        && (message["approval"] as? [String: Any])?["state"] as? String == "pending"
                }
            }
            guard !text.isEmpty, replyTo != nil else {
                return json(request, 400, ["error": "Answer the approval with the button you chose."])
            }
            guard open else {
                return json(request, 409, ["error": "This approval is no longer waiting for an answer."])
            }
            let approved = answer["approved"] as? Bool ?? false
            setApproval(approvalID, state: approved ? "working" : "declined")
            let turn = UUID().uuidString.lowercased()
            setTurn(turn, status: "running")
            let id = body["clientMessageId"] as? String ?? UUID().uuidString.lowercased()
            lock.withLock { _messages.append(["id": id, "role": "user", "text": text, "turnId": turn, "createdAt": "2026-11-20T10:00:01.000Z", "attachments": []]) }
            return json(request, 200, ["threadId": threadID, "turnId": turn, "messageId": id])
        }
        let attachmentIDs = body["attachmentIds"] as? [String] ?? []
        let attachments = lock.withLock { attachmentIDs.compactMap { id in _uploads.first { $0["id"] as? String == id } } }
        guard attachments.count == attachmentIDs.count else { return json(request, 400, ["error": "An attachment is unavailable."]) }
        guard !text.isEmpty || !attachments.isEmpty else { return json(request, 400, ["error": "Check the supplied values."]) }
        let id = body["clientMessageId"] as? String ?? UUID().uuidString.lowercased()
        if let previous = lock.withLock({ _messages.first { $0["id"] as? String == id } }) {
            // The same message again: Nod answers with what it did the first time.
            let before = (previous["attachments"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            guard previous["text"] as? String == text, before == attachmentIDs else {
                return json(request, 409, ["error": "This message ID is already in use. Send this as a new message."])
            }
            return json(request, 200, ["threadId": threadID, "turnId": previous["turnId"] ?? NSNull(), "messageId": id])
        }
        let turn = UUID().uuidString.lowercased()
        setTurn(turn, status: "running")
        lock.withLock { _messages.append(["id": id, "role": "user", "text": text, "turnId": turn, "createdAt": "2026-11-20T10:00:00.000Z", "attachments": attachments]) }
        return json(request, 200, ["threadId": threadID, "turnId": turn, "messageId": id])
    }

    private func record(_ request: URLRequest) -> Call {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let call = Call(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            query: request.url?.query,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: body
        )
        lock.withLock { _calls.append(call) }
        return call
    }

    private func response(_ request: URLRequest, _ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func json(_ request: URLRequest, _ status: Int, _ object: [String: Any]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), response(request, status, ["Content-Type": "application/json"]))
    }
}

/// Collects what a request's stream reports.
actor EventLog {
    private(set) var events: [NodEvent] = []
    private(set) var failure: (any Error)?
    private(set) var finished = false

    func add(_ event: NodEvent) { events.append(event) }
    func end(_ error: (any Error)?) {
        failure = error
        finished = true
    }

    var text: String {
        events.reduce(into: "") { text, event in if case .textDelta(let piece) = event { text += piece } }
    }

    static func following(_ stream: AsyncThrowingStream<NodEvent, any Error>) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let task = Task {
            do {
                for try await event in stream { await log.add(event) }
                await log.end(nil)
            } catch {
                await log.end(error)
            }
        }
        return (log, task)
    }
}
