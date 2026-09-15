import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Privacy disclosure")
struct PrivacyDisclosureTests {
    @Test("Privacy manifest declares lobby identity and gameplay, and does not track")
    func privacyManifestMatchesLobby() throws {
        let plist = try Self.propertyList("ASTROSPIKE/PrivacyInfo.xcprivacy")
        #expect(plist["NSPrivacyTracking"] as? Bool == false)

        let types = try #require(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let ids = Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(ids.contains("NSPrivacyCollectedDataTypeUserID"))
        #expect(ids.contains("NSPrivacyCollectedDataTypeName"))
        #expect(ids.contains("NSPrivacyCollectedDataTypeGameplayContent"))

        for entry in types {
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            #expect(purposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"))
        }
    }

    @Test("Privacy policy admits CloudKit lobby records instead of claiming nothing leaves")
    func privacyPolicyTellsTheTruth() throws {
        let html = try Self.text("docs/privacy-policy.html")
        let lower = html.lowercased()
        #expect(!lower.contains("does not collect, store, or share any personal data"))
        #expect(!lower.contains("everything the app remembers stays on your device"))
        #expect(lower.contains("cloudkit") || lower.contains("icloud"))
        #expect(lower.contains("game center"))
        #expect(lower.contains("display name") || lower.contains("player name"))
        #expect(lower.contains("hull"))
    }

    @Test("Support page does not repeat the old no-data claim")
    func supportPagePointsAtThePolicy() throws {
        let html = try Self.text("docs/support.html")
        #expect(!html.lowercased().contains("collects no personal data"))
        #expect(html.contains("privacy-policy.html"))
    }

    @Test("In-app legal links are the hosted pages")
    func legalLinksAreHosted() {
        #expect(LegalLinks.privacyPolicy.absoluteString == "https://iankainoa42.github.io/ASTROSPIKE/privacy-policy.html")
        #expect(LegalLinks.termsOfUse.absoluteString == "https://iankainoa42.github.io/ASTROSPIKE/terms.html")
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func text(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private static func propertyList(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent(relative))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(object as? [String: Any])
    }
}
