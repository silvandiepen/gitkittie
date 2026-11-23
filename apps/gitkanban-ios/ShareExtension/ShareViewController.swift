import SwiftUI
import UIKit

/// Entry point of the "Tasks" share extension: hosts `ShareView` and hands it the
/// shared items. All board work goes through the shared `AppModel` (GitKanbanKit).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let share = ShareModel(providers: items.flatMap { $0.attachments ?? [] })
        let root = ShareView(
            share: share,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            onDone: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
