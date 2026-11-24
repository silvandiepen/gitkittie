import Foundation

/// The synthetic fixture corpus (GKM-003). Never real mail, never a real address.
public enum MailFixtures {
    /// The folder the fixtures are copied to in the test bundle.
    public static var directory: URL? { Bundle.module.url(forResource: "Fixtures", withExtension: nil) }
}
