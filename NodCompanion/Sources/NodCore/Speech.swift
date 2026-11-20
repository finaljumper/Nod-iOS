import Foundation

/// Speaks text aloud. Implementations queue utterances and play them in order.
@MainActor
public protocol SpeechOutput: AnyObject {
    func speak(_ segment: SpeechSegment)
    /// Stops at once and drops everything queued.
    func stop()
    /// Falls silent at once but keeps what is queued, until `resume` or `stop`.
    func pause()
    /// Goes on where `pause` fell silent.
    func resume()
    /// Called when speaking starts or the queue runs empty.
    var onSpeakingChanged: (@MainActor (Bool) -> Void)? { get set }
}

extension SpeechOutput {
    public func pause() {}
    public func resume() {}
}

public enum SpeechInputAvailability: Sendable, Equatable {
    case ready
    case unavailable(String)
}

public enum SpeechInputEvent: Sendable, Equatable {
    /// The user has started to talk. Sent by recognisers that listen continuously.
    case speechStarted
    /// The transcript so far; it may still change.
    case partial(String)
    /// The finished transcript of one utterance. It can be empty when nothing was understood.
    case final(String)
    /// Something the user should know while waiting, such as a speech model being downloaded.
    case notice(String)
}

/// Turns the user's speech into text. Which recogniser does it is decided elsewhere; the
/// conversation logic only needs this much of it.
@MainActor
public protocol SpeechInput: AnyObject {
    var availability: SpeechInputAvailability { get }
    /// Starts listening. With `continuous` false the stream ends after the first `.final`.
    /// With `continuous` true the recogniser keeps listening, finds the start and end of each
    /// utterance itself, and sends one `.final` per utterance until it is cancelled.
    func start(languages: [String], continuous: Bool) -> AsyncThrowingStream<SpeechInputEvent, Error>
    /// The user has stopped talking: finish the transcript and deliver `.final`.
    func finish()
    /// Stop listening and discard what was heard.
    func cancel()
    /// The utterance just delivered was the app's own voice. A recogniser that listens while
    /// the app speaks takes this as a sign to be harder to trigger.
    func noteEcho()
}

extension SpeechInput {
    public func noteEcho() {}
}

/// Stands in until a speech recogniser is attached.
@MainActor
public final class NoSpeechInput: SpeechInput {
    public static let reason = "No speech recogniser is attached yet. Type your message instead."

    public init() {}

    public var availability: SpeechInputAvailability { .unavailable(Self.reason) }

    public func start(languages: [String], continuous: Bool) -> AsyncThrowingStream<SpeechInputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func finish() {}
    public func cancel() {}
}

/// Pretends to hear fixed phrases, word by word. For development and tests only: it lets the
/// listening and dialogue flows be exercised without a microphone.
@MainActor
public final class ScriptedSpeechInput: SpeechInput {
    private let phrases: [String]
    private let wordDelay: Double
    private let pauseBetweenPhrases: Double
    private let loops: Bool
    private let sleep: @Sendable (Double) async throws -> Void
    private var nextPhrase = 0
    private var task: Task<Void, Never>?
    private var finishRequested = false

    /// - Parameters:
    ///   - pauseBetweenPhrases: continuous listening only: the silence before each phrase.
    ///   - loops: continuous listening only: start again from the first phrase after the last.
    ///     Without it the recogniser hears nothing more after the last phrase, and keeps
    ///     listening until it is cancelled, as a microphone would.
    public init(
        phrases: [String] = ScriptedSpeechInput.defaultPhrases,
        wordDelay: Double = 0.25,
        pauseBetweenPhrases: Double = 7,
        loops: Bool = true,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.phrases = phrases.isEmpty ? ScriptedSpeechInput.defaultPhrases : phrases
        self.wordDelay = wordDelay
        self.pauseBetweenPhrases = pauseBetweenPhrases
        self.loops = loops
        self.sleep = sleep
    }

    public static let defaultPhrases = [
        "What is on my calendar today?",
        "내일 오전 미팅 끝나고 feedback 정리해 줘",
        "Send an email to Alex about Friday",
        "오늘 일정 알려 줘",
    ]

    public var availability: SpeechInputAvailability { .ready }

    public func start(languages: [String], continuous: Bool) -> AsyncThrowingStream<SpeechInputEvent, Error> {
        finishRequested = false
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                defer { continuation.finish() }
                guard let self else { return }
                repeat {
                    if continuous {
                        do { try await self.sleep(self.pauseBetweenPhrases) } catch { return }
                        continuation.yield(.speechStarted)
                    }
                    let words = self.phrases[self.nextPhrase % self.phrases.count].split(separator: " ").map(String.init)
                    self.nextPhrase += 1
                    var heard: [String] = []
                    for word in words {
                        if self.finishRequested { break }
                        do { try await self.sleep(self.wordDelay) } catch { return }
                        heard.append(word)
                        continuation.yield(.partial(heard.joined(separator: " ")))
                    }
                    if Task.isCancelled { return }
                    self.finishRequested = false
                    continuation.yield(.final(heard.joined(separator: " ")))
                } while continuous && !Task.isCancelled && (self.loops || self.nextPhrase < self.phrases.count)
                while continuous, !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func finish() { finishRequested = true }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
