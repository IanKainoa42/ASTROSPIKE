import Foundation
import Testing
@testable import ASTROSPIKECore

struct AppUpdateTests {
    @Test func numericVersionComparisonHandlesPatchAndTrailingZeros() {
        #expect(AppUpdatePolicy.isVersionNewer("1.0.3", than: "1.0.2"))
        #expect(AppUpdatePolicy.isVersionNewer("1.1", than: "1.0.9"))
        #expect(AppUpdatePolicy.isVersionNewer("2.0", than: "1.9.9"))
        #expect(!AppUpdatePolicy.isVersionNewer("1.0.0", than: "1.0"))
        #expect(!AppUpdatePolicy.isVersionNewer("1.0.1", than: "1.0.2"))
    }

    @Test func testFlightInstallDetectsNewerBuildFromManifestOrLobby() {
        let fromManifest = AppUpdatePolicy.evaluate(
            installedVersion: "1.0.2",
            installedBuild: 185,
            installedWire: 67,
            isTestFlightOrSandbox: true,
            manifest: AppBuildManifest(version: "1.0.2", build: 186, wire: 67)
        )
        #expect(fromManifest == AvailableAppUpdate(
            latestVersion: "1.0.2",
            latestBuild: 186,
            latestWire: 67,
            source: .testFlight
        ))
        #expect(fromManifest?.buttonTitle == "UPDATE AVAILABLE · BUILD 186")
        #expect(fromManifest?.subtitle == "TAP TO UPDATE IN TESTFLIGHT")

        let fromLobby = AppUpdatePolicy.evaluate(
            installedVersion: "1.0.2",
            installedBuild: 185,
            installedWire: 67,
            isTestFlightOrSandbox: true,
            highestLobbyBuild: 187
        )
        #expect(fromLobby?.latestBuild == 187)
        #expect(fromLobby?.source == .testFlight)
    }

    @Test func wireProtocolMismatchSurfacesUpdateEvenWithoutManifest() {
        let update = AppUpdatePolicy.evaluate(
            installedVersion: "1.0.2",
            installedBuild: 185,
            installedWire: 67,
            isTestFlightOrSandbox: true,
            highestPeerWire: 68
        )
        #expect(update?.latestWire == 68)
        #expect(update?.buttonTitle == "UPDATE AVAILABLE")
    }

    @Test func appStoreInstallDetectsNewerMarketingVersionAndIgnoresTestFlightBuildNumbers() {
        let ignoredBuild = AppUpdatePolicy.evaluate(
            installedVersion: "1.0.2",
            installedBuild: 185,
            installedWire: 67,
            isTestFlightOrSandbox: false,
            manifest: AppBuildManifest(version: "1.0.2", build: 190, wire: 67),
            highestLobbyBuild: 190
        )
        #expect(ignoredBuild == nil)

        let storeUpdate = AppUpdatePolicy.evaluate(
            installedVersion: "1.0.2",
            installedBuild: 185,
            installedWire: 67,
            isTestFlightOrSandbox: false,
            appStoreVersion: "1.1.0"
        )
        #expect(storeUpdate == AvailableAppUpdate(
            latestVersion: "1.1.0",
            latestBuild: nil,
            latestWire: nil,
            source: .appStore
        ))
        #expect(storeUpdate?.buttonTitle == "UPDATE AVAILABLE · V1.1.0")
        #expect(storeUpdate?.subtitle == "TAP TO UPDATE ON THE APP STORE")
    }

    @Test func pilotPresenceMatchIDEncodingPreservesLiveTagsAndCarriesBuildWhenIdle() {
        let idleEncoded = PilotPresence.encodeMatchID(matchID: nil, build: 185)
        #expect(idleEncoded == "build:185")
        let idleDecoded = PilotPresence.decodeMatchID(idleEncoded)
        #expect(idleDecoded.matchID == nil)
        #expect(idleDecoded.build == 185)

        let liveEncoded = PilotPresence.encodeMatchID(matchID: "return:abc", build: 185)
        #expect(liveEncoded == "return:abc")
        let liveDecoded = PilotPresence.decodeMatchID(liveEncoded)
        #expect(liveDecoded.matchID == "return:abc")
        #expect(liveDecoded.build == nil)
    }
}

    @Test func appStoreInstallFailsToDetectUpdateFromTestFlightWire() {
        let update = AppUpdatePolicy.evaluate(
            installedVersion: "1.0.2",
            installedBuild: 185,
            installedWire: 67,
            isTestFlightOrSandbox: false,
            manifest: AppBuildManifest(version: "1.0.2", build: 190, wire: 70)
        )
        #expect(update == nil)
    }
