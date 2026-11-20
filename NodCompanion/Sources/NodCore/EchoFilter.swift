import Foundation

/// Tells whether what the recogniser heard is the app's own voice coming back through the
/// microphone. The system removes most of that, but not always all of it, and what is left
/// is recognised as the very words the app was saying.
public enum EchoFilter {
    /// - Parameters:
    ///   - heard: the transcript of an utterance that began while the app was speaking.
    ///   - spoken: what the app was saying around that time.
    ///   - threshold: the share of what was heard that has to be found, in order, in what
    ///     was spoken. High on purpose: a short answer from the user often shares a word or
    ///     two with what the app just said ("yes, send it" after "shall I send it?").
    /// - Returns: true for an echo and for an utterance without words, which is noise.
    public static func isEcho(heard: String, spoken: String, threshold: Double = 0.75) -> Bool {
        let heard = tokens(heard)
        guard !heard.isEmpty else { return true }
        let spoken = tokens(spoken)
        guard !spoken.isEmpty else { return false }
        return Double(commonInOrder(heard, spoken)) / Double(heard.count) >= threshold
    }

    /// Words in lower case without punctuation. Korean, Chinese and Japanese are cut into
    /// pairs of characters instead, because a recogniser does not space them as the text did.
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var tokens: [String] = []
        for word in folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let characters = Array(word)
            guard characters.contains(where: isUnspaced) else {
                tokens.append(String(word))
                continue
            }
            if characters.count == 1 {
                tokens.append(String(word))
            } else {
                for index in 0..<(characters.count - 1) { tokens.append(String(characters[index...index + 1])) }
            }
        }
        return tokens
    }

    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(scalar)     // Hangul syllables
            || (0x3040...0x30FF).contains(scalar)     // Kana
            || (0x4E00...0x9FFF).contains(scalar)     // CJK ideographs
    }

    /// The length of the longest run of tokens that appears in both, in the same order but
    /// not necessarily next to each other.
    private static func commonInOrder(_ first: [String], _ second: [String]) -> Int {
        var previous = [Int](repeating: 0, count: second.count + 1)
        for token in first {
            var current = [Int](repeating: 0, count: second.count + 1)
            for (index, other) in second.enumerated() {
                current[index + 1] = token == other ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[second.count]
    }
}
