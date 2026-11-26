import StoreKit

/// Where this copy of the app came from.
public enum AppDistribution {
    /// True only for a copy the App Store installed: a signed app transaction from the production
    /// store. TestFlight (sandbox), Xcode builds and copies with no App Store receipt are false,
    /// and so is anything StoreKit cannot verify; those never offer an update.
    public static func isAppStore() async -> Bool {
        let result: VerificationResult<AppTransaction>
        do {
            result = try await AppTransaction.shared
        } catch {
            // No app transaction to read (a local build): not from the App Store.
            return false
        }
        guard case .verified(let transaction) = result else { return false }
        return transaction.environment == .production
    }
}
