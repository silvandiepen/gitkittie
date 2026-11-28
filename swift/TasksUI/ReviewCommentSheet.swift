import GitKanbanKit
import GitKittieKit
import SwiftUI

// Writing to the agent about review files, the same on the Mac and the iPhone: asking for
// changes (which needs a message: `ReviewStatus.needsComment`) or a plain comment, on one file
// or many at once. The comments already written in the request are offered to use again.

/// What the comment sheet sends.
enum ReviewCommentPurpose: Equatable {
    /// Ask for changes on these files: the message is what to change, and it is required.
    case changes(files: Int)
    /// A comment on these files.
    case comment(files: Int)

    var title: String {
        switch self {
        case .changes(let files): return files == 1 ? "Ask for Changes" : "Ask for Changes on \(files) Files"
        case .comment(let files): return files == 1 ? "Comment" : "Comment on \(files) Files"
        }
    }

    var action: String {
        switch self {
        case .changes: return "Ask Changes"
        case .comment: return "Add Comment"
        }
    }

    var prompt: String {
        switch self {
        case .changes(let files): return files == 1 ? "What should change?" : "What should change? Each file gets this message."
        case .comment(let files): return files == 1 ? "For the agent to read." : "Each file gets this comment, for the agent to read."
        }
    }
}

/// What a comment sheet is open for: the purpose, the files it names, and what to do with
/// the text. Identifiable so a view can present it with `.sheet(item:)`.
struct ReviewCommentRequest: Identifiable {
    let id = UUID()
    var purpose: ReviewCommentPurpose
    /// The file's name, or nil for several.
    var subject: String?
    var suggestions: [String]
    var send: (String) -> Void
}

/// A message to the agent: a text field that has the focus when the sheet opens, the comments
/// already written in this request as one-tap suggestions, and a send button that waits for
/// text when asking for changes.
struct ReviewCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: ReviewCommentRequest
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("changeCommentCancel")
                Spacer()
                Text(request.purpose.title).font(.headline)
                Spacer()
                Button(request.purpose.action) {
                    let message = text
                    dismiss()
                    request.send(message)
                }
                .fontWeight(.semibold)
                .disabled(!canSend)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("changeCommentSend")
            }
            VStack(alignment: .leading, spacing: 6) {
                if let subject = request.subject {
                    Text(subject).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                }
                Text(request.purpose.prompt).font(.footnote).foregroundStyle(.secondary)
            }
            TextField(requiresText ? "What to change" : "Comment", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .focused($focused)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke) }
                .accessibilityIdentifier("changeCommentField")
            if !request.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Said earlier in this review").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ReviewCommentSuggestions(suggestions: request.suggestions) { text = $0 }
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 260)
        #else
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.window)
        #endif
        .task {
            // A sheet takes the focus once it is on screen; set at once it is lost on iOS.
            try? await Task.sleep(nanoseconds: 300_000_000)
            focused = true
        }
    }

    private var requiresText: Bool {
        if case .changes = request.purpose { return true } else { return false }
    }
}

/// Earlier comments as chips: one tap puts that text in the field.
struct ReviewCommentSuggestions: View {
    let suggestions: [String]
    let use: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { use(suggestion) } label: {
                    Text(suggestion)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.card, in: Capsule())
                        .overlay { Capsule().strokeBorder(Theme.stroke) }
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(suggestion)
                .accessibilityHint("Puts this comment in the field")
            }
        }
    }
}

/// The same suggestions as a menu, beside a comment field that is already on screen.
struct ReviewCommentSuggestionMenu: View {
    let suggestions: [String]
    let use: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            Menu {
                Section("Said earlier in this review") {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { use(suggestion) }
                    }
                }
            } label: {
                Image(systemName: "text.badge.plus")
                    #if os(iOS)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    #endif
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Use a comment written earlier in this review")
            #endif
            .accessibilityLabel("Earlier comments")
            .accessibilityIdentifier("reviewCommentSuggestions")
        }
    }
}
