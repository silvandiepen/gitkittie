import GitKanbanKit
import GitKittieKit
import SwiftUI

// The notes of a review request: the Markdown under its frontmatter, where the agent says
// how the files were made and what to look at. Shared by the Mac and iPhone apps, drawn as
// formatted Markdown with the pictures it shows (GITKITTIE-107).

/// A request's notes taken apart into blocks, once per text: a long request's notes run to
/// thousands of lines and the screens draw them on every change.
@MainActor
enum ReviewNotes {
    private static var parsed: [String: [MarkdownBlocks.Block]] = [:]

    static func blocks(_ request: ReviewRequest) -> [MarkdownBlocks.Block] {
        let text = request.body
        if let hit = parsed[text] { return hit }
        let blocks = MarkdownBlocks.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if parsed.count > 64 { parsed.removeAll() }
        parsed[text] = blocks
        return blocks
    }

    /// How many blocks a folded-up preview shows: up to the first pictures or the second
    /// heading, at most six blocks.
    static func previewCount(_ blocks: [MarkdownBlocks.Block]) -> Int {
        var headings = 0
        for (index, block) in blocks.enumerated() {
            if index >= 6 { return index }
            switch block {
            case .images: return index + 1
            case .heading:
                headings += 1
                if headings == 2, index > 0 { return index }
            default: break
            }
        }
        return blocks.count
    }
}

/// Blocks of a request's notes, each its own view: inside a lazy stack only the ones on
/// screen are laid out.
struct ReviewNotesRows: View {
    let blocks: ArraySlice<MarkdownBlocks.Block>

    var body: some View {
        ForEach(Array(zip(blocks.indices, blocks)), id: \.0) { _, block in
            MarkdownBlockView(block: block)
        }
    }
}

/// The notes in a sheet of their own (iPhone, iPad): the whole text, lazily.
struct ReviewNotesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReviewRequest

    var body: some View {
        let blocks = ReviewNotes.blocks(request)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let question = request.question {
                        Text(MarkdownPage.inline(question)).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ReviewNotesRows(blocks: blocks[...])
                }
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .reviewImages(model: model, request: request)
            .navigationTitle("Notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension View {
    /// Pictures in Markdown below this view load from the request's folder.
    func reviewImages(model: AppModel, request: ReviewRequest, maxPixel: Int = 1200) -> some View {
        environment(\.markdownImageLoader, MarkdownImageLoader(
            load: { source in
                guard !isRemote(source) else { return nil }
                return await ReviewImageCache.load(model, request, file: source, maxPixel: maxPixel)
            },
            cached: { source in ReviewImageCache.cached(request, file: source, maxPixel: maxPixel) }))
    }
}

/// A picture on the web rather than in the request's folder: it is not fetched.
private func isRemote(_ source: String) -> Bool {
    source.contains("://") || source.hasPrefix("data:")
}
