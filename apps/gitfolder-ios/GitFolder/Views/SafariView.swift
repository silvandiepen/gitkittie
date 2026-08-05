import SafariServices
import SwiftUI

/// `SFSafariViewController` wrapped for SwiftUI, used to run GitHub's device-flow
/// authorisation page inside the app instead of handing off to the default browser.
/// Sign-in must not leave the app (App Store guideline 4 — Design), and Safari View
/// Controller still shows the real URL and certificate so the user can verify the
/// page before typing credentials.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
