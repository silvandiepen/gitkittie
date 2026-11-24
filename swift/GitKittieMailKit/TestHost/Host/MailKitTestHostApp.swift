import SwiftUI

/// Test-only: hosts the Mail kit's WebKit tests on iOS (see ../project.yml). Never shipped.
@main
struct MailKitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("GitKittie Mail test host")
        }
    }
}
