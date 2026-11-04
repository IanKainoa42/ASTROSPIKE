import Foundation

/// Published version metadata for the latest build of the app.
public struct AppBuildManifest: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var wire: UInt16?

    public init(version: String, build: Int, wire: UInt16? = nil) {
        self.version = version
        self.build = build
        self.wire = wire
    }
}

/// Describes an update that is ready for the player to install.
public struct AvailableAppUpdate: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case testFlight
        case appStore
    }

    public var latestVersion: String?
    public var latestBuild: Int?
    public var latestWire: UInt16?
    public var source: Source

    public init(
        latestVersion: String? = nil,
        latestBuild: Int? = nil,
        latestWire: UInt16? = nil,
        source: Source
    ) {
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.latestWire = latestWire
        self.source = source
    }

    public var buttonTitle: String {
        if let latestBuild, latestBuild > 0 {
            return "UPDATE AVAILABLE · BUILD \(latestBuild)"
        }
        if let latestVersion, !latestVersion.isEmpty {
            return "UPDATE AVAILABLE · V\(latestVersion.uppercased())"
        }
        return "UPDATE AVAILABLE"
    }

    public var subtitle: String {
        switch source {
        case .testFlight:
            return "TAP TO UPDATE IN TESTFLIGHT"
        case .appStore:
            return "TAP TO UPDATE ON THE APP STORE"
        }
    }
}

/// Pure version/build comparison rules so update detection is testable in ASTROSPIKECore.
public enum AppUpdatePolicy {
    /// Returns true when `candidate` is strictly newer than `installed` using
    /// dot-separated numeric version components (e.g. "1.0.2" > "1.0.1", "1.0.0" == "1.0").
    public static func isVersionNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = parseVersionComponents(candidate)
        let rhs = parseVersionComponents(installed)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        let count = max(lhs.count, rhs.count)
        for index in 0 ..< count {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parseVersionComponents(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.split(separator: ".")
        var numbers: [Int] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard let value = Int(digits) else { return [] }
            numbers.append(value)
        }
        return numbers
    }

    /// Evaluates all known version signals and returns an `AvailableAppUpdate` when
    /// a newer build, wire protocol, or marketing version is available.
    public static func evaluate(
        installedVersion: String,
        installedBuild: Int,
        installedWire: UInt16,
        isTestFlightOrSandbox: Bool,
        manifest: AppBuildManifest? = nil,
        highestLobbyBuild: Int? = nil,
        highestPeerWire: UInt16? = nil,
        appStoreVersion: String? = nil
    ) -> AvailableAppUpdate? {
        let source: AvailableAppUpdate.Source = isTestFlightOrSandbox ? .testFlight : .appStore
        let remoteBuild = max(manifest?.build ?? 0, highestLobbyBuild ?? 0)
        let remoteWire = max(manifest?.wire ?? 0, highestPeerWire ?? 0)

        // 1. On TestFlight/sandbox installs, a higher build number from the manifest
        //    or from another pilot in the CloudKit lobby means a newer build is out.
        if isTestFlightOrSandbox, installedBuild > 0, remoteBuild > installedBuild {
            return AvailableAppUpdate(
                latestVersion: manifest?.version,
                latestBuild: remoteBuild,
                latestWire: remoteWire > installedWire ? remoteWire : manifest?.wire,
                source: .testFlight
            )
        }

        // 2. A newer wire protocol version (from manifest or live Game Center peer)
        //    means this build cannot duel the latest field until updated.
        if remoteWire > installedWire {
            return AvailableAppUpdate(
                latestVersion: manifest?.version ?? appStoreVersion,
                latestBuild: remoteBuild > installedBuild ? remoteBuild : nil,
                latestWire: remoteWire,
                source: source
            )
        }

        // 3. A newer marketing version on the App Store (or manifest).
        if let appStoreVersion, isVersionNewer(appStoreVersion, than: installedVersion) {
            return AvailableAppUpdate(
                latestVersion: appStoreVersion,
                latestBuild: (isTestFlightOrSandbox && remoteBuild > installedBuild) ? remoteBuild : nil,
                latestWire: nil,
                source: source
            )
        }

        if isTestFlightOrSandbox,
           let manifestVersion = manifest?.version,
           isVersionNewer(manifestVersion, than: installedVersion) {
            return AvailableAppUpdate(
                latestVersion: manifestVersion,
                latestBuild: remoteBuild > installedBuild ? remoteBuild : nil,
                latestWire: manifest?.wire,
                source: .testFlight
            )
        }

        return nil
    }
}
