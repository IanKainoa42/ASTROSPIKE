import Testing
@testable import ASTROSPIKECore

@Suite("Player-facing network copy")
struct PlayerNetworkCopyTests {
    @Test("Game Center copy never leaks GK codes or engineer jargon")
    func gameCenterCopyIsForPilots() {
        for kind in PlayerNetworkCopy.GameCenter.allCases {
            let text = kind.message
            #expect(!text.contains("GK"), "\(kind): \(text)")
            #expect(!text.contains("#"), "\(kind): \(text)")
            #expect(!text.isEmpty, "\(kind) has no copy")
        }
        #expect(PlayerNetworkCopy.GameCenter.notAuthenticated.message == "Sign in to Game Center in Settings")
        #expect(PlayerNetworkCopy.GameCenter.cancelled.message == "Search cancelled")
        #expect(PlayerNetworkCopy.GameCenter.communicationsFailure.message == "Couldn't reach Game Center")
        #expect(PlayerNetworkCopy.GameCenter.other.message == "Couldn't reach Game Center. Try again.")
    }

    @Test("CloudKit copy never leaks schema/deploy jargon")
    func cloudKitCopyIsForPilots() {
        for kind in PlayerNetworkCopy.CloudKit.allCases {
            let text = kind.message
            #expect(!text.contains("CK"), "\(kind): \(text)")
            #expect(!text.uppercased().contains("SCHEMA"), "\(kind): \(text)")
            #expect(!text.uppercased().contains("DEPLOY"), "\(kind): \(text)")
            #expect(!text.uppercased().contains("INDEX"), "\(kind): \(text)")
        }
        #expect(PlayerNetworkCopy.CloudKit.unknownItem.message == "Lobby isn't available yet")
        #expect(PlayerNetworkCopy.CloudKit.network.message == "No network. Pull to refresh.")
        #expect(PlayerNetworkCopy.CloudKit.notAuthenticated.message == "Sign in to iCloud")
        #expect(PlayerNetworkCopy.CloudKit.other.message == "Couldn't reach iCloud. Pull to refresh.")
    }

    @Test("The bay names who the pilot is waiting on")
    func matchmakingHeadlineNamesThePilot() {
        #expect(PlayerNetworkCopy.Matchmaking.joining("Ian") == "JOINING IAN…")
        #expect(PlayerNetworkCopy.Matchmaking.rejoining("Maya") == "REJOINING MAYA…")
        #expect(PlayerNetworkCopy.Matchmaking.awaitingReinvite("Maya") == "LINK DROPPED · ACCEPT MAYA'S NEW INVITE")
        #expect(PlayerNetworkCopy.Matchmaking.waiting(for: ["Maya"]) == "WAITING FOR MAYA…")
        #expect(PlayerNetworkCopy.Matchmaking.waiting(for: ["Maya", "Jo", "Sam"]) == "WAITING FOR MAYA +2…")
        #expect(PlayerNetworkCopy.Matchmaking.waiting(for: []) == "WAITING FOR PILOTS…")
    }

    @Test("Invite replies are something a waiting pilot can act on")
    func inviteCopyIsForPilots() {
        #expect(PlayerNetworkCopy.Invite.declined.message == "Declined")
        #expect(PlayerNetworkCopy.Invite.incompatible.message == "They need to update")
        #expect(PlayerNetworkCopy.Invite.failed.message == "Invite didn't arrive")
        #expect(PlayerNetworkCopy.Invite.noAnswer.message == "No answer")
        for kind in PlayerNetworkCopy.Invite.allCases {
            #expect(!kind.message.contains("INCOMPATIBLE"))
            #expect(!kind.message.contains("FAILED TO DELIVER"))
        }
    }
}
