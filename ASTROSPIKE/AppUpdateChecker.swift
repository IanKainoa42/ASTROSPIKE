import ASTROSPIKECore
import Foundation
import Observation
import UIKit

/// Watches for newer builds or versions of ASTROSPIKE and opens TestFlight or
/// the App Store directly from the menu.
@MainActor
@Observable
final class AppUpdateChecker {
    static let shared = AppUpdateChecker()

    static let appStoreID = "6805938755"
    static let bundleID = "com.iankainoa.ASTROSPIKE"
    static let manifestURL = URL(string: "https://iankainoa42.github.io/ASTROSPIKE/version.json")!
    static let testFlightURL = URL(string: "itms-beta://beta.itunes.apple.com/v1/app/\(appStoreID)")!
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id\(appStoreID)")!

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static var isTestFlightOrSandbox: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private(set) var availableUpdate: AvailableAppUpdate?
    private(set) var isChecking = false

    private var manifest: AppBuildManifest?
    private var appStoreVersion: String?
    private var highestLobbyBuild: Int?
    private var highestPeerWire: UInt16?
    private let previewMode: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        previewMode = arguments.contains("-updatePreview") || arguments.contains("--update-preview")
        if previewMode {
            let nextBuild = max(1, Self.installedBuild + 1)
            availableUpdate = AvailableAppUpdate(
                latestVersion: Self.installedVersion,
                latestBuild: nextBuild,
                latestWire: WireEnvelope.currentVersion + 1,
                source: .testFlight
            )
        }
    }

    /// Checks the published version manifest and App Store lookup for updates.
    func refresh() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        async let fetchedManifest = Self.fetchManifest()
        async let fetchedStoreVersion = Self.fetchAppStoreVersion()

        if let m = await fetchedManifest {
            manifest = m
        }
        if let v = await fetchedStoreVersion {
            appStoreVersion = v
        }
        reevaluate()
    }

    /// Records build numbers seen on CloudKit `Pilot` records in the lobby.
    func noteLobbyBuilds(_ builds: [Int]) {
        guard let maxBuild = builds.max(), maxBuild > 0 else { return }
        if maxBuild > (highestLobbyBuild ?? 0) {
            highestLobbyBuild = maxBuild
            reevaluate()
        }
    }

    /// Records a peer's wire protocol version when a packet fails with a mismatch.
    func noteRemoteWireVersion(_ wireVersion: UInt16) {
        guard wireVersion > WireEnvelope.currentVersion else { return }
        if wireVersion > (highestPeerWire ?? 0) {
            highestPeerWire = wireVersion
            reevaluate()
        }
    }

    /// Opens TestFlight (for TestFlight/sandbox installs) or the App Store so
    /// the player can update immediately from the menu.
    func openUpdate() {
        let preferTestFlight = (availableUpdate?.source ?? (Self.isTestFlightOrSandbox ? .testFlight : .appStore)) == .testFlight
        if preferTestFlight {
            UIApplication.shared.open(Self.testFlightURL) { opened in
                if !opened {
                    Task { @MainActor in
                        UIApplication.shared.open(Self.appStoreURL)
                    }
                }
            }
        } else {
            UIApplication.shared.open(Self.appStoreURL)
        }
    }

    private func reevaluate() {
        if previewMode { return }
        availableUpdate = AppUpdatePolicy.evaluate(
            installedVersion: Self.installedVersion,
            installedBuild: Self.installedBuild,
            installedWire: WireEnvelope.currentVersion,
            isTestFlightOrSandbox: Self.isTestFlightOrSandbox,
            manifest: manifest,
            highestLobbyBuild: highestLobbyBuild,
            highestPeerWire: highestPeerWire,
            appStoreVersion: appStoreVersion
        )
    }

    private static func fetchManifest() async -> AppBuildManifest? {
        var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "_", value: String(Int(Date.now.timeIntervalSince1970 / 60)))]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(AppBuildManifest.self, from: data)
    }

    private struct ITunesLookupResponse: Decodable {
        struct Entry: Decodable {
            let version: String?
        }
        let results: [Entry]
    }

    private static func fetchAppStoreVersion() async -> String? {
        let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleID)&_=\(Int(Date.now.timeIntervalSince1970 / 60))"
        guard let url = URL(string: urlString) else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ITunesLookupResponse.self, from: data) else { return nil }
        return decoded.results.first?.version
    }
}
