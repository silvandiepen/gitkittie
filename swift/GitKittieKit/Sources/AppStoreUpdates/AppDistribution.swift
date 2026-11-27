import Foundation
import StoreKit

/// Where this copy of the app came from.
public enum AppDistribution {
    /// True only for a copy the App Store installed: a signed app transaction from the production
    /// store. TestFlight (sandbox), Xcode builds and copies with no App Store receipt are false,
    /// and so is anything StoreKit cannot verify; those never offer an update.
    ///
    /// StoreKit is asked only when the bundle already holds a production receipt. Asking
    /// `AppTransaction.shared` in a copy without one makes the system fetch it from the store,
    /// and on a Mac that means a "Sign in to your Apple Account" alert at launch (GITKITTIE-110):
    /// a team-signed Release build of Tasks did exactly that. A copy the App Store installed
    /// always carries its receipt, so the file is enough to tell the two apart without asking.
    public static func isAppStore(bundle: Bundle = .main) async -> Bool {
        guard receipt(at: bundle.appStoreReceiptURL) == .production else { return false }
        let result: VerificationResult<AppTransaction>
        do {
            result = try await AppTransaction.shared
        } catch {
            // No app transaction to read: not from the App Store.
            return false
        }
        guard case .verified(let transaction) = result else { return false }
        return transaction.environment == .production
    }

    /// What the bundle's App Store receipt says about where it came from.
    public enum Receipt: Equatable, Sendable {
        /// No receipt, or an empty file: an Xcode, Developer ID or team-signed build, or a copy
        /// whose receipt was removed. StoreKit must not be asked: it would ask to sign in.
        case missing
        /// A sandbox receipt (`sandboxReceipt`): TestFlight or an Xcode build. Never an update offer.
        case sandbox
        /// A production receipt with content: the App Store installed this copy.
        case production
    }

    /// Reads the receipt at `url` (the bundle's `appStoreReceiptURL`) without touching StoreKit.
    public static func receipt(at url: URL?, fileManager: FileManager = .default) -> Receipt {
        guard let url else { return .missing }
        // TestFlight and Xcode builds point at `sandboxReceipt`, whether or not the file exists.
        if url.lastPathComponent == "sandboxReceipt" { return .sandbox }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else { return .missing }
        return .production
    }
}
