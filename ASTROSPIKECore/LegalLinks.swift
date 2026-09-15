import Foundation

/// Hosted legal pages for App Review and the Hangar footer.
///
/// GitHub Pages serves `docs/` at this origin. Keep the paths in lockstep
/// with the HTML files in that folder.
public enum LegalLinks {
    public static let privacyPolicy = URL(string: "https://iankainoa42.github.io/ASTROSPIKE/privacy-policy.html")!
    public static let termsOfUse = URL(string: "https://iankainoa42.github.io/ASTROSPIKE/terms.html")!
}
