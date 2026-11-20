import Foundation

/// One block of a message written in Markdown.
public enum MarkdownBlock: Equatable, Sendable {
    public struct ListItem: Equatable, Sendable {
        /// "•" for a bullet, "1." and so on for a numbered item.
        public var marker: String
        /// How deeply the item is nested; 0 is the outermost level.
        public var level: Int
        public var text: String

        public init(marker: String, level: Int, text: String) {
            self.marker = marker
            self.level = level
            self.text = text
        }
    }

    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ListItem])
    case code(language: String?, text: String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
}

/// Cuts Markdown into blocks. Emphasis, links and inline code inside a block are left for
/// the view to style. Written for replies that are still arriving: a code block that has not
/// been closed yet simply runs to the end.
public enum MarkdownParser {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                closeParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                closeParagraph()
                index += 1
                continue
            }
            if let heading = heading(trimmed) {
                closeParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if isRule(trimmed) {
                closeParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                closeParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(lines[index].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if listItem(line) != nil {
                closeParagraph()
                var items: [MarkdownBlock.ListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index]) {
                        items.append(item)
                    } else if !items.isEmpty, lines[index].hasPrefix("  "), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        // An indented line continues the item above it.
                        items[items.count - 1].text += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
                closeParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[index])
                    // Every row gets as many cells as the header has.
                    row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        closeParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return nil }
        if "-*+".contains(first), rest.dropFirst().first == " " {
            return .init(marker: "•", level: indent / 2, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isNumber }
        let after = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 9, let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
            return .init(marker: "\(digits).", level: indent / 2, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
