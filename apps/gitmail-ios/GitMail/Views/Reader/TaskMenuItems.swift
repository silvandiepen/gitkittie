import MailCore
import SwiftUI
import UIKit

/// Make Task and Copy Link for one message (GKM-033), in the reader's More menu and the row
/// menu. Make Task opens GitKittie Tasks' new-task sheet with the subject, who it is from and
/// a link back; nothing is saved there until Create.
struct TaskMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let messageID: MailMessageID

    var body: some View {
        Button("Make Task…", systemImage: "checklist") {
            Task {
                guard let handoff = await model.taskHandoff(for: messageID) else { return }
                openURL(handoff.url) { accepted in
                    if !accepted { model.actionError = TaskHandoff.notInstalled }
                }
            }
        }
        Button("Copy Link to Message", systemImage: "link") {
            Task {
                guard let link = await model.link(to: messageID) else { return }
                UIPasteboard.general.url = link.url
            }
        }
    }
}
