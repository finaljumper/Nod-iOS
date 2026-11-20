import Foundation

/// The HTTP the app needs, so that tests can stand in for the network.
public protocol NodHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A response whose body arrives over time, as lines without their line endings. Empty
    /// lines are delivered too: they end a frame of an event stream.
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
}

/// The network through URLSession: no cookies, no cache, and redirects are not followed, so
/// that the key is never carried to another address.
public final class URLSessionNodHTTP: NodHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // `bytes.lines` drops empty lines, which an event stream needs, so the lines are cut here.
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}

/// Why a request to Nod did not give what was asked for.
public enum NodError: Error, Equatable, Sendable {
    /// No key is stored on this device.
    case noKey
    /// 401: the key was not accepted.
    case unauthorized(String)
    /// 403 from Nod: it does not answer at this address.
    case forbidden(String)
    /// 409: what the request refers to has changed, for example an approval that is over.
    case conflict(String, code: String?)
    /// Another refusal that Nod explained.
    case refused(Int, String)
    /// The address sent the app somewhere else, as a sign-in page in front of Nod does.
    case redirected
    /// The answer did not come from Nod, or not in a form this app knows.
    case notNod(Int)
    /// Nod or something in front of it failed.
    case server(Int)
    case unreachable(String)

    /// Whether the same request can succeed later without anything being changed.
    public var isTransient: Bool {
        switch self {
        case .server, .unreachable: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .noKey:
            return "No authentication key is stored. Set up the connection in Settings."
        case .unauthorized:
            return "Nod did not accept the authentication key."
        case .forbidden(let reason):
            return "Nod refused this address: \(reason) Its NOD_PUBLIC_URL has to be exactly the address entered here."
        case .conflict(let reason, _), .refused(_, let reason):
            return reason
        case .redirected:
            return "The address leads to another page instead of Nod. A sign-in in front of it, such as Cloudflare Access, is not supported."
        case .notNod(let status):
            return "The address answered, but not as Nod (status \(status))."
        case .server(let status):
            return "Nod could not be reached through its address (status \(status))."
        case .unreachable(let reason):
            return reason
        }
    }
}

/// Typed requests to one Nod server.
public struct NodClient: Sendable {
    public let baseURL: URL
    private let key: String?
    private let http: any NodHTTP

    public init(baseURL: URL, key: String?, http: any NodHTTP = URLSessionNodHTTP()) {
        self.baseURL = baseURL
        self.key = key
        self.http = http
    }

    // MARK: Requests

    /// Answers 401 without a key, which is how setup tells that an address is Nod.
    public func health() async throws {
        struct Health: Decodable { var ok: Bool? }
        _ = try await send(request("api/health"), as: Health.self)
    }

    public func session() async throws -> NodAPI.Session {
        try await send(request("api/session"), as: NodAPI.Session.self)
    }

    public func state() async throws -> NodAPI.State {
        try await send(request("api/state"), as: NodAPI.State.self)
    }

    /// Sends a user message. `clientMessageID` becomes the message's identifier on Nod: the
    /// same message sent again with it is answered with the first result and not acted on twice.
    public func sendMessage(text: String, threadID: String, clientMessageID: UUID, attachmentIDs: [String] = []) async throws -> NodAPI.Submitted {
        struct Body: Encodable {
            var text: String
            var threadId: String
            var clientMessageId: String
            /// Left out when there are none: Nod refuses fields it does not expect.
            var attachmentIds: [String]?
        }
        let body = Body(
            text: text, threadId: threadID, clientMessageId: clientMessageID.uuidString.lowercased(),
            attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs)
        return try await send(request("api/messages", method: "POST", body: body), as: NodAPI.Submitted.self)
    }

    /// Stores a file on Nod for a message that is about to be sent. Nod keeps such a file
    /// for a limited time until a message refers to it.
    public func upload(name: String, mimeType: String, data: Data) async throws -> NodAPI.Attachment {
        let boundary = "nod-" + UUID().uuidString
        // A quote or line break in the name would break the form's header.
        let safeName = name.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try request("api/uploads", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // A photo over a mobile connection can take a while.
        request.timeoutInterval = 300
        return try await send(request, as: NodAPI.Attachment.self)
    }

    /// Answers an approval. Nod wants it as a reply to the message that asked, with the text
    /// of the button that was pressed.
    public func answerApproval(threadID: String, messageID: String, approvalID: String, approved: Bool, text: String, clientMessageID: UUID) async throws -> NodAPI.Submitted {
        struct Body: Encodable {
            struct Answer: Encodable {
                var approvalId: String
                var approved: Bool
            }

            var text: String
            var threadId: String
            var clientMessageId: String
            var replyToMessageId: String
            var approvalAnswer: Answer
        }
        let body = Body(
            text: text,
            threadId: threadID,
            clientMessageId: clientMessageID.uuidString.lowercased(),
            replyToMessageId: messageID,
            approvalAnswer: .init(approvalId: approvalID, approved: approved)
        )
        return try await send(request("api/messages", method: "POST", body: body), as: NodAPI.Submitted.self)
    }

    /// Stops all of the agent's work in the conversation.
    public func stopThread() async throws {
        struct Stopped: Decodable { var ok: Bool? }
        _ = try await send(request("api/thread/stop", method: "POST"), as: Stopped.self)
    }

    /// Nod's live events. The stream ends when the connection does and throws a `NodError`
    /// when it could not be opened.
    public func events(account: String) -> AsyncThrowingStream<NodAPI.Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try self.request("api/events", query: [URLQueryItem(name: "account", value: account)])
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Nod sends a keepalive every 15 s; a minute of silence means the line is dead.
                    request.timeoutInterval = 60
                    let (response, lines) = try await http.lines(for: request)
                    guard response.statusCode == 200 else {
                        var body = ""
                        for try await line in lines where body.count < 4096 { body += line }
                        throw Self.failure(status: response.statusCode, body: Data(body.utf8))
                    }
                    guard response.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
                        throw NodError.notNod(response.statusCode)
                    }
                    var parser = SSEParser()
                    for try await line in lines {
                        if let payload = parser.feed(line) { continuation.yield(NodAPI.Event(payload: payload)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.error(from: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: (any Encodable)? = nil) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw NodError.notNod(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The key is sent in this header only: never in the address, never in a log.
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        return request
    }

    private func send<Answer: Decodable>(_ request: URLRequest, as type: Answer.Type) async throws -> Answer {
        do {
            let (data, response) = try await http.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.failure(status: response.statusCode, body: data)
            }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                throw NodError.notNod(response.statusCode)
            }
            return answer
        } catch {
            throw Self.error(from: error)
        }
    }

    static func failure(status: Int, body: Data) -> NodError {
        if (300..<400).contains(status) { return .redirected }
        let failure = try? JSONDecoder().decode(NodAPI.Failure.self, from: body)
        guard let reason = failure?.error, !reason.isEmpty else {
            // Not Nod's own error: something in front of it answered.
            return status >= 500 ? .server(status) : .notNod(status)
        }
        switch status {
        case 401: return .unauthorized(reason)
        case 403: return .forbidden(reason)
        case 409: return .conflict(reason, code: failure?.code)
        case 503: return .refused(status, reason)
        case 500...: return .server(status)
        default: return .refused(status, reason)
        }
    }

    static func error(from error: any Error) -> any Error {
        if error is NodError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : NodError.unreachable(urlError.localizedDescription)
        }
        return NodError.unreachable(error.localizedDescription)
    }
}

/// The two checks of the connection setup: is this address Nod, and is this key accepted.
public enum NodConnectionCheck {
    /// Asks the address for something that needs a key, without one. Nod answers that with
    /// its own 401, which nothing else in front of it would.
    public static func address(_ url: URL, http: any NodHTTP = URLSessionNodHTTP()) async -> Result<Void, NodError> {
        do {
            try await NodClient(baseURL: url, key: nil, http: http).health()
            return .success(())
        } catch NodError.unauthorized {
            return .success(())
        } catch let error as NodError {
            return .failure(error)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// Returns the name of the account the key belongs to, if Nod gives one.
    public static func key(_ key: String, at url: URL, http: any NodHTTP = URLSessionNodHTTP()) async -> Result<String?, NodError> {
        do {
            let session = try await NodClient(baseURL: url, key: key, http: http).session()
            return .success(session.user?.name)
        } catch let error as NodError {
            return .failure(error)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// The parts of the check at the end of setup, in the order they are made. Together they
    /// are everything the app needs from Nod. Nothing is sent to the agent: every part only reads.
    public enum Part: Sendable, CaseIterable, Equatable {
        /// Nod answers at the address.
        case address
        /// The key is accepted and belongs to an account.
        case key
        /// The conversation can be read.
        case conversation
        /// Nod's live updates reach this device, which is how replies arrive.
        case liveUpdates
    }

    /// Makes one part of the final check with the address and key that are about to be saved.
    /// - Parameter patience: how long to wait for the first live update. Nod sends one as
    ///   soon as the stream opens, so a long silence means something holds the stream back.
    public static func verify(
        _ part: Part, key: String, at url: URL,
        http: any NodHTTP = URLSessionNodHTTP(), patience: Duration = .seconds(12)
    ) async -> Result<Void, NodError> {
        let client = NodClient(baseURL: url, key: key, http: http)
        do {
            switch part {
            case .address:
                try await client.health()
            case .key:
                guard try await client.session().user != nil else { throw NodError.notNod(200) }
            case .conversation:
                _ = try await client.state()
            case .liveUpdates:
                guard let account = try await client.session().user?.id else { throw NodError.notNod(200) }
                try await firstEvent(of: client, account: account, within: patience)
            }
            return .success(())
        } catch let error as NodError {
            return .failure(error)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// Waits until the stream of live events has delivered something, then closes it.
    private static func firstEvent(of client: NodClient, account: String, within patience: Duration) async throws {
        let silent = NodError.unreachable("Nod's live updates do not arrive. Something between this device and Nod, such as a proxy that collects the answer before passing it on, holds them back. Replies would not show up.")
        let arrived = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await _ in client.events(account: account) { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: patience)
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        if !arrived { throw silent }
    }
}
