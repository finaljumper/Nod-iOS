import NodCore
import SwiftUI

/// A message written in Markdown, laid out block by block: paragraphs, headings, lists, code,
/// quotes and tables. Content layer: no glass, only fills.
struct MarkdownText: View {
    let text: String
    /// Large type for the dialogue screen, where the reply is read from further away.
    var isLarge = false

    var body: some View {
        let blocks = MarkdownParser.blocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(isLarge ? .title2 : nil)
    }

    private func headingFont(_ level: Int) -> Font {
        if isLarge { return level == 1 ? .title.bold() : .title2.bold() }
        return level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold()
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language).font(isLarge ? .footnote : .caption2).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(code).font(isLarge ? .body.monospaced() : .callout.monospaced())
                }
                .scrollIndicators(.hidden)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 10))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.secondary).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell))
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Emphasis, inline code and links inside one block. Text that is not valid Markdown,
    /// as happens while a reply is still arriving, is shown as it is.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
