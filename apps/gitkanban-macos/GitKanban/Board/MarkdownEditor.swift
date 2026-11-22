import AppKit
import GitKittieKit
import SwiftUI

/// A Markdown editor that shows the text half-rendered while you type, the way Lezin does:
/// the characters stay exactly as written, but headings grow, bold reads bold, code tints
/// and the syntax markers fade (`MarkdownSourceStyler`). It reports its content height so
/// the caller can let it grow with the text up to a limit.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    var fontSize: CGFloat = NSFont.systemFontSize
    /// False shows the text for reading: it can be selected and copied, not changed.
    var isEditable = true
    /// ⌘↩ in the editor.
    var onCommit: () -> Void = {}
    /// Lets a toolbar outside the editor apply formatting to its selection.
    var commands: MarkdownCommands?

    /// The colour of links and code in the editor. The system accent is too dark to read
    /// on the dark panel and too light on the white one, so this is a blue chosen for each.
    static let readableAccent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.80, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.32, blue: 0.75, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // The editor is as tall as its text and sits in the panel's own scroll view, so it
        // never scrolls by itself and hands the wheel on.
        let scrollView = PassthroughScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = CommitTextView()
        textView.onCommit = { [weak coordinator = context.coordinator] in coordinator?.parent.onCommit() }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.setAccessibilityLabel("Description, Markdown")
        textView.string = text
        scrollView.documentView = textView

        context.coordinator.textView = textView
        commands?.textView = textView
        context.coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        commands?.textView = textView
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
        }
        context.coordinator.restyle()
    }

    /// A scroll view that does not scroll: wheel events go to whatever encloses it.
    final class PassthroughScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    }

    /// An `NSTextView` that hands ⌘↩ to its owner instead of inserting a line break, and
    /// edits Markdown the way Lezin does: Tab, Shift-Tab and Return work on lists, and
    /// the formatting shortcuts toggle the Markdown around the selection.
    final class CommitTextView: NSTextView {
        var onCommit: () -> Void = {}

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, event.modifierFlags.contains(.command) { onCommit(); return }
            if isEditable, let action = Self.shortcut(for: event) { applyMarkdownFormat(action); return }
            super.keyDown(with: event)
        }

        override func insertTab(_ sender: Any?) { if !handleMarkdownListTab() { super.insertTab(sender) } }
        override func insertBacktab(_ sender: Any?) { if !handleMarkdownListBacktab() { super.insertBacktab(sender) } }
        override func insertNewline(_ sender: Any?) { if !handleMarkdownListNewline() { super.insertNewline(sender) } }

        /// ⌘B, ⌘I, ⌘E (code), ⇧⌘X (strikethrough), ⌥⌘1–3 (headings), ⇧⌘7 / ⇧⌘8 (lists), ⇧⌘. (quote).
        static func shortcut(for event: NSEvent) -> MarkdownFormatAction? {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
            switch (flags, key) {
            case ([.command], "b"): return .bold
            case ([.command], "i"): return .italic
            case ([.command], "e"): return .code
            case ([.command, .shift], "x"): return .strikethrough
            case ([.command, .option], "1"): return .heading1
            case ([.command, .option], "2"): return .heading2
            case ([.command, .option], "3"): return .heading3
            case ([.command, .shift], "7"): return .orderedList
            case ([.command, .shift], "8"): return .bulletList
            case ([.command, .shift], "."): return .quote
            default: return nil
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            restyle()
        }

        /// Re-apply the Markdown styling and report the height the text needs.
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let palette = MarkdownSourceStyler.Palette(
                baseFont: .systemFont(ofSize: parent.fontSize), textColor: .labelColor, accentColor: MarkdownEditor.readableAccent)
            MarkdownSourceStyler.apply(to: storage, palette: palette)
            textView.typingAttributes = [.font: palette.baseFont, .foregroundColor: palette.textColor]
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
            if abs(height - parent.contentHeight) > 0.5 {
                // Not during the view update that called us.
                DispatchQueue.main.async { [parent] in parent.contentHeight = height }
            }
        }
    }
}

/// Calls `action` when the pointer is over the view and a two-finger swipe to the right
/// ends on it: the trackpad way to push a side panel away. Scroll events are only
/// watched, never consumed, so scrolling the panel keeps working.
struct SwipeRightToClose: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.action = action }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var action: () -> Void = {}
        private var monitor: Any?
        private var travelled = CGSize.zero
        private var fired = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.watch(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func watch(_ event: NSEvent) {
            // Only real trackpad gestures (they have phases), and only over this panel.
            guard event.window === window, event.hasPreciseScrollingDeltas,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if event.phase == .began {
                travelled = .zero
                fired = false
            }
            guard event.phase == .changed, !fired else { return }
            travelled.width += event.scrollingDeltaX
            travelled.height += event.scrollingDeltaY
            // Clearly sideways and to the right, not a vertical scroll that drifted.
            if travelled.width > 70, abs(travelled.width) > abs(travelled.height) * 2.5 {
                fired = true
                action()
            }
        }
    }
}

/// The handle a formatting toolbar holds on an editor.
@MainActor
final class MarkdownCommands {
    weak var textView: NSTextView?

    func apply(_ action: MarkdownFormatAction) {
        guard let textView, textView.isEditable else { return }
        textView.window?.makeFirstResponder(textView)
        textView.applyMarkdownFormat(action)
    }
}

extension NSTextView {
    /// Toggle a Markdown format on the selection, as one undoable edit.
    func applyMarkdownFormat(_ action: MarkdownFormatAction) {
        let result = MarkdownFormatter.apply(action, to: string, selection: selectedRange())
        guard result.text != string else { setSelectedRange(result.selection); return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: result.text) else { return }
        replaceCharacters(in: whole, with: result.text)
        didChangeText()
        setSelectedRange(result.selection)
    }
}

/// Lezin's formatting buttons, for above an editor.
struct MarkdownFormatBar: View {
    let commands: MarkdownCommands
    private let actions: [MarkdownFormatAction] = [.heading1, .heading2, .heading3, .bold, .italic, .strikethrough, .code, .bulletList, .orderedList, .quote, .plainText]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions, id: \.self) { action in
                Button { commands.apply(action) } label: {
                    Image(systemName: action.systemImage).frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless)
                .help(action.title)
                .accessibilityLabel(action.title)
                if action == .heading3 || action == .code || action == .quote { Divider().frame(height: 14).padding(.horizontal, 3) }
            }
        }
    }
}
