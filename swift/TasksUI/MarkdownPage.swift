import GitKittieKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Markdown as a page: headings, paragraphs, code blocks with a copy button, note boxes,
/// lists whose checkboxes can be ticked, tables. Shared by the Mac and iPhone apps.
struct MarkdownPage: View {
    let markdown: String
    /// Called with a checkbox's number when it is ticked or unticked; nil shows them read-only.
    var onToggle: ((Int) -> Void)?

    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title.weight(.bold) : level == 2 ? .title2.weight(.bold) : level == 3 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 8 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.body).lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in row(item) }
            }
        case .quote(let kind, let text):
            NoteBox(kind: kind, text: Self.inline(text))
        case .table(let header, let rows):
            table(header, rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func row(_ item: MarkdownBlocks.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let checked = item.checked {
                Button {
                    if let index = item.checkIndex { onToggle?(index) }
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .disabled(onToggle == nil || item.checkIndex == nil)
                .accessibilityLabel(checked ? "Done" : "Not done")
                .accessibilityHint("Changes the task")
            } else if let number = item.number {
                Text(number).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("•").font(.body).foregroundStyle(.secondary)
            }
            Text(Self.inline(item.text)).font(.body)
                .strikethrough(item.checked == true)
                .foregroundStyle(item.checked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(item.indent / 2, 6)) * 14)
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(Self.inline(cell)).font(.callout.weight(.semibold))
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell)).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// A block's text with its inline marks (bold, code, links) styled.
    static func inline(_ text: String) -> AttributedString {
        var styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in styled.runs where run.link != nil {
            styled[run.range].underlineStyle = .single
        }
        return styled
    }
}

/// A fenced code block: its language, a copy button, and the code in a fixed-width face.
private struct CodeBlock: View {
    let language: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    #if canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #else
                    UIPasteboard.general.string = text
                    #endif
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "square.on.square")
                        .font(.callout).foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// A quote, drawn as a box. One that starts with `[!NOTE]`, `[!WARNING]` and the like
/// names itself and takes that kind's colour.
private struct NoteBox: View {
    let kind: String?
    let text: AttributedString

    private var look: (title: String, symbol: String, color: Color)? {
        switch kind {
        case "NOTE": return ("Note", "info.circle", .blue)
        case "TIP": return ("Tip", "lightbulb", .green)
        case "IMPORTANT": return ("Important", "exclamationmark.bubble", .purple)
        case "WARNING": return ("Warning", "exclamationmark.triangle", .orange)
        case "CAUTION": return ("Caution", "exclamationmark.octagon", .red)
        case .some(let other): return (other.capitalized, "info.circle", .blue)
        case nil: return nil
        }
    }

    var body: some View {
        let color = look?.color ?? .secondary
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let look { Image(systemName: look.symbol).font(.title3).foregroundStyle(look.color) }
            VStack(alignment: .leading, spacing: 3) {
                if let look { Text(look.title).font(.body.weight(.semibold)) }
                Text(text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(color.opacity(0.10))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }
}
