import AppStoreUpdates
import SwiftUI

// "Update available": every GitKittie app asks the App Store at most once a day whether a newer
// version is out (AppStoreUpdates in swift/GitKittieKit) and, when one is, shows a quiet notice
// with Update, which opens the app's App Store page, and Not Now, which hides that version.

/// The running app's update state. One per app, owned by its root view.
@MainActor @Observable
final class AppUpdates {
    /// The newer version to offer, or nil.
    private(set) var offer: UpdateOffer?
    @ObservationIgnored private let checker: UpdateChecker?
    @ObservationIgnored private var isChecking = false

    init() {
        checker = UpdateChecker(bundle: .main)
    }

    /// Asks the store when a day has passed since the last answer. Debug builds, TestFlight and
    /// copies that did not come from the App Store never ask and never offer.
    func check() async {
        if Self.isDebugBuild {
            // `GITKITTIE_UPDATE_OFFER=<version>`: show the notice in a debug build, for screenshots.
            if let version = ProcessInfo.processInfo.environment["GITKITTIE_UPDATE_OFFER"] {
                offer = UpdateOffer(version: version, storeURL: AppStoreLookup.storeURL(trackID: 0, platform: .current))
            }
            return
        }
        guard let checker, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard await AppDistribution.isAppStore() else { return }
        offer = await checker.check()
    }

    // Checked at run time rather than with `#if` around the code, so CI's debug builds still
    // compile the release path.
    #if DEBUG
    private static let isDebugBuild = true
    #else
    private static let isDebugBuild = false
    #endif

    /// Not now: this version is not offered again; a later one is.
    func dismiss() {
        guard let offer else { return }
        checker?.dismiss(offer)
        self.offer = nil
    }
}

extension View {
    /// Checks for an update when the app starts and each time it comes forward; the checker
    /// itself keeps that to one request a day.
    func checksForAppUpdates(_ updates: AppUpdates) -> some View {
        modifier(AppUpdateCheck(updates: updates))
    }
}

private struct AppUpdateCheck: ViewModifier {
    let updates: AppUpdates
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: scenePhase == .active) {
            if scenePhase == .active { await updates.check() }
        }
    }
}

/// "Update available — version X", with Update and Not Now. Draws nothing without an offer.
struct UpdateAvailableNotice: View {
    let updates: AppUpdates
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let offer = updates.offer {
            VStack(alignment: .leading, spacing: spacing) {
                Label("Update available", systemImage: "arrow.down.circle")
                    .font(titleFont)
                Text("Version \(offer.version) is in the App Store.")
                    .font(detailFont).foregroundStyle(.secondary)
                HStack {
                    Button("Update") { openURL(offer.storeURL) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("updateAvailableUpdate")
                    Button("Not Now") { updates.dismiss() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("updateAvailableDismiss")
                }
                #if os(macOS)
                .controlSize(.small)
                #endif
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius))
            #if os(macOS)
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.stroke))
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("updateAvailable")
        }
    }

    // A sidebar card on the Mac, a home-screen card on the iPhone and iPad, matching the
    // "New board" suggestion each app already shows in the same place.
    #if os(macOS)
    private let spacing: CGFloat = 6
    private let padding: CGFloat = 10
    private let radius: CGFloat = 10
    private let titleFont = Font.callout.weight(.semibold)
    private let detailFont = Font.caption
    #else
    private let spacing: CGFloat = 10
    private let padding: CGFloat = 16
    private let radius: CGFloat = 16
    private let titleFont = Font.headline
    private let detailFont = Font.callout
    #endif
}

/// The same offer as a menu item, for an app whose only surface is a menu (Folder on the Mac).
/// Draws nothing without an offer.
struct UpdateAvailableMenu: View {
    let updates: AppUpdates
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let offer = updates.offer {
            Menu("Update Available — Version \(offer.version)", systemImage: "arrow.down.circle") {
                Button("Update in the App Store…") { openURL(offer.storeURL) }
                Button("Not Now") { updates.dismiss() }
            }
            Divider()
        }
    }
}
