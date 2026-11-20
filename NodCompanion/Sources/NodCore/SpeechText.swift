import Foundation

/// Cuts streamed reply text into sentences, so that speaking can start before the whole reply
/// has arrived.
public struct SentenceChunker: Sendable {
    private var buffer = ""

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    /// Sentence ends that need no following space.
    private static let wideTerminators: Set<Character> = ["。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»"]

    public init() {}

    /// Adds text and returns the sentences that are now complete.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        var start = buffer.startIndex
        var index = buffer.startIndex

        func emit(upTo end: String.Index) {
            let sentence = buffer[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }

        while index < buffer.endIndex {
            let character = buffer[index]
            if character.isNewline {
                emit(upTo: index)
                index = buffer.index(after: index)
                start = index
            } else if Self.wideTerminators.contains(character) {
                index = buffer.index(after: index)
                emit(upTo: index)
                start = index
            } else if Self.terminators.contains(character) {
                var end = buffer.index(after: index)
                while end < buffer.endIndex, Self.terminators.contains(buffer[end]) || Self.closers.contains(buffer[end]) {
                    end = buffer.index(after: end)
                }
                // "3." may still become "3.5", and a full stop at the very end may be followed
                // by more of the same word: wait for the white space that settles it.
                if end < buffer.endIndex, buffer[end].isWhitespace {
                    emit(upTo: end)
                    start = end
                }
                index = end
            } else {
                index = buffer.index(after: index)
            }
        }
        buffer = String(buffer[start...])
        return sentences
    }

    /// Returns what is left when the reply has ended.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    public mutating func reset() { buffer = "" }
}

/// A piece of text to be spoken by a voice of one language.
public struct SpeechSegment: Sendable, Equatable {
    public var text: String
    /// Language code: `en`, `ru` or `ko`.
    public var language: String

    public init(text: String, language: String) {
        self.text = text
        self.language = language
    }
}

/// Splits text by writing system, because a synthetic voice reads only its own language well.
public enum LanguageSegmenter {
    /// The language a character belongs to: Cyrillic is read as Russian, Hangul as Korean and
    /// Latin letters as `latin`. Digits, punctuation and spaces belong to no language.
    public static func language(of character: Character, latin: String = "en") -> String? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return "ru"
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return "ko"
        default:
            return character.isLetter && scalar.value < 0x0250 ? latin : nil
        }
    }

    /// Runs of one language. Digits, punctuation and spaces stay with the run before them, so a
    /// number is read in the language of the words around it.
    public static func segments(of text: String, latin: String = "en", fallback: String = "en") -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        var current = ""
        var currentLanguage: String?

        func close() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
                segments.append(SpeechSegment(text: trimmed, language: currentLanguage ?? fallback))
            }
            current = ""
        }

        for character in text {
            if let language = language(of: character, latin: latin) {
                if let currentLanguage, currentLanguage != language { close() }
                currentLanguage = language
            }
            current.append(character)
        }
        close()
        return segments
    }
}

/// Removes what should be read with the eyes only: Markdown marks, links and code.
public enum SpeechTextSanitizer {
    public static func clean(_ text: String) -> String {
        var result = text
        // [label](https://…) is spoken as its label; a bare address is not spoken.
        result = result.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
        result = result.replacing(/https?:\/\/\S+/, with: " ")
        // Heading marks, list bullets and quote marks at the start of a line.
        result = result.replacing(/(?m)^\s{0,3}(#{1,6}|[-*+]|>)\s+/, with: "")
        // Code fences, inline code marks, emphasis marks and table bars.
        result = result.replacing(/```[A-Za-z0-9]*/, with: " ")
        result = result.replacing(/[`*_|~]+/, with: " ")
        result = result.replacing(/[ \t]{2,}/, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
