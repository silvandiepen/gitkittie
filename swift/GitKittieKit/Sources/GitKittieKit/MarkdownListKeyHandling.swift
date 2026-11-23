// Taken from Lezin (`lezin/apps/editor-kit`, MarkdownListKeyHandling.swift, at origin/main 97dc7d7) so Tasks edits
// Markdown with the same commands as Lezin. Keep it in step with Lezin; do not change it here.

#if os(macOS)
import AppKit

/// Wires `MarkdownListEditing` into an `NSTextView`.
///
/// Both editors — the full app's `DragDropTextView` and Lite's
/// `LiteNSTextView` — call these from their `insertTab`, `insertBacktab` and
/// Return handling, so Tab, Shift-Tab and Return behave identically in the two
/// apps. Each returns whether the key was dealt with; `false` means fall back
/// to the text view's own behaviour.
public extension NSTextView {
    func handleMarkdownListTab() -> Bool {
        applyMarkdownListOutcome(MarkdownListEditing.tab(in: string, selection: selectedRange()))
    }

    func handleMarkdownListBacktab() -> Bool {
        applyMarkdownListOutcome(MarkdownListEditing.backtab(in: string, selection: selectedRange()))
    }

    func handleMarkdownListNewline() -> Bool {
        applyMarkdownListOutcome(MarkdownListEditing.newline(in: string, selection: selectedRange()))
    }

    private func applyMarkdownListOutcome(_ outcome: MarkdownListOutcome) -> Bool {
        switch outcome {
        case .unhandled:
            return false
        case .consumed:
            return true
        case .handled(let edit):
            // Through shouldChangeText/didChangeText so the edit joins the
            // view's own undo stack and the delegate hears about it.
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
            replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
            setSelectedRange(edit.selection)
            return true
        }
    }
}
#endif
