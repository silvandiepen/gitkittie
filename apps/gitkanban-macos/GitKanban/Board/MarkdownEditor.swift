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
    /// ⌘↩ in the editor.
    var onCommit: () -> Void = {}

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
        context.coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
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

    /// An `NSTextView` that hands ⌘↩ to its owner instead of inserting a line break.
    final class CommitTextView: NSTextView {
        var onCommit: () -> Void = {}
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, event.modifierFlags.contains(.command) { onCommit() } else { super.keyDown(with: event) }
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
                baseFont: .systemFont(ofSize: parent.fontSize), textColor: .labelColor, accentColor: .controlAccentColor)
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
