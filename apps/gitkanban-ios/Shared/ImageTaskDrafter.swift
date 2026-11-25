import GitKanbanKit
import GitKittieKit
import SwiftUI

extension ImageTaskDrafter {
    /// One line on who drafts and what they can see, or why nobody does.
    static func status(_ app: AppModel) -> String {
        if let cloud = app.imageAnalysisProvider {
            return "Drafted by \(cloud.displayName), which looks at the image itself."
        }
        if OnDeviceAI.isAvailable {
            return "Drafted on this device from your comments and the text in the image. The on-device model cannot see the picture itself; add an AI key in Tasks (account menu, AI Settings) for that."
        }
        return "Nothing is drafting: \(OnDeviceAI.unavailableReason ?? "no AI is available.") Add an AI key in Tasks (account menu, AI Settings) to have tasks written from the image."
    }
}

/// Said at the top of a form when no model can write the task: otherwise the title is
/// silently the first comment and nothing tells why.
struct NoDraftingNotice: View {
    let app: AppModel

    var body: some View {
        if ImageTaskDrafter.provider(app) == nil {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The task will not be written for you").font(.subheadline.weight(.semibold))
                        Text(OnDeviceAI.unavailableReason ?? "No AI is available.")
                        Text("Check Settings → Apple Intelligence & Siri, or add an AI key in Tasks (account menu → AI Settings). Until then the title is your first comment and the description is what you type.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .accessibilityIdentifier("noDraftingNotice")
            }
        }
    }
}
