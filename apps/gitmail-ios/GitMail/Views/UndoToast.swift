import Combine
import SwiftUI

/// After an archive, a move to Trash or a flag: what happened and Undo, for a few seconds,
/// through the action journal (MAIL-037).
struct UndoToast: View {
    let undo: UndoManager
    @State private var name: String?
    @State private var hide: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        Group {
            if let name {
                HStack(spacing: 16) {
                    Text(name).font(.subheadline.weight(.medium))
                    Button("Undo") {
                        undo.undo()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("undoButton")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 60)
                // Reduce Motion: it fades in place instead of sliding up.
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: name)
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: undo)) { _ in
            guard !undo.isUndoing, !undo.isRedoing, undo.canUndo else { return }
            let done = undo.undoActionName.isEmpty ? "Done" : undo.undoActionName
            name = done
            // VoiceOver hears what happened, and gets longer to reach Undo than a glance needs.
            AccessibilityNotification.Announcement("\(done). Undo is available.").post()
            hide?.cancel()
            hide = Task {
                try? await Task.sleep(for: .seconds(voiceOver ? 12 : 4))
                if !Task.isCancelled { dismiss() }
            }
        }
    }

    private func dismiss() {
        hide?.cancel()
        name = nil
    }
}
