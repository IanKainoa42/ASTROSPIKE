import CloudKit
@preconcurrency import GameKit
import ASTROSPIKECore
import Observation
import os

/// The lobby's link to CloudKit. Publishes this pilot's presence and the
/// duels they host, and reads everyone else's.
///
/// Everything lives in the public database and every record is written only
/// by the pilot who created it: one `Pilot` per player, one `Duel` per hosted
/// match, and for tournaments a `Tournament` record from the organizer plus a
/// `TournamentEntry` per joiner and a `TournamentReport` per decided fixture.
/// Nothing is ever edited by two players, so there are no shared writes to
/// fight over; the bracket is rebuilt from the records on every read.
@MainActor
@Observable
final class LobbyService {
    enum Availability: Equatable {
        case checking
        /// iCloud account present: this pilot shows up in the lobby.
        case live
        /// Lobby readable, but nothing can be published.
        case readOnly(String)
        case offline(String)

        var label: String {
            switch self {
            case .checking: "CHECKING ICLOUD…"
            case .live: "LOBBY LIVE"
            case let .readOnly(reason), let .offline(reason): reason.uppercased()
            }
        }
    }

    static let containerIdentifier = "iCloud.com.iankainoa.ASTROSPIKE"
    static let heartbeatSeconds = 30
    static let pollSeconds = 6

    private(set) var availability: Availability = .checking
    private(set) var snapshot = LobbySnapshot()
    private(set) var friends: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// The last thing that went wrong, shown in the lobby. Nil when all is well.
    private(set) var notice: String?
    /// Rolling log of lobby events, oldest first, for the diagnostics panel.
    private(set) var eventLog: [String] = []

    private(set) var activity: PilotActivity = .idle
    private(set) var currentMatchID: String?
    /// Set by the app from the pilot profile; published with the heartbeat.
    var localHull: Hull = .lancet

    /// The duel this pilot is hosting, mirrored to CloudKit as the score moves.
    private(set) var hostedDuel: LiveMatch?
    private var hostedDuelRecord: CKRecord?
    private var presenceRecord: CKRecord?

    private let database = CKContainer(identifier: LobbyService.containerIdentifier).publicCloudDatabase
    private let container = CKContainer(identifier: LobbyService.containerIdentifier)
    private var heartbeatTask: Task<Void, Never>?
    private var isStarted = false

    private static let logger = Logger(subsystem: "com.iankainoa.ASTROSPIKE", category: "Lobby")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var localID: String? {
        GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.gamePlayerID : nil
    }

    var localName: String { GKLocalPlayer.local.displayName }
    var canPublish: Bool { availability == .live && localID != nil }

    // MARK: - Lifecycle

    /// Call once Game Center is signed in and again whenever the app comes to
    /// the foreground. Checks iCloud and starts the heartbeat.
    func start() {
        guard localID != nil else { return }
        if !isStarted {
            isStarted = true
            note("LOBBY: START AS \(localName)")
        }
        Task { await checkAccount() }
        loadFriends()
        beginHeartbeat()
    }

    /// The app is leaving the foreground. The presence simply goes stale.
    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func setActivity(_ activity: PilotActivity, matchID: String? = nil) {
        guard self.activity != activity || currentMatchID != matchID else { return }
        self.activity = activity
        currentMatchID = matchID
        Task { await publishPresence() }
    }

    private func checkAccount() async {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                if availability != .live { note("ICLOUD: AVAILABLE") }
                availability = .live
            case .noAccount:
                availability = .readOnly("Sign in to iCloud to appear in the lobby")
            case .restricted:
                availability = .readOnly("iCloud restricted · lobby is read-only")
            case .temporarilyUnavailable:
                availability = .readOnly("iCloud waking up · lobby is read-only")
            case .couldNotDetermine:
                availability = .readOnly("iCloud status unknown · lobby is read-only")
            @unknown default:
                availability = .readOnly("iCloud status unknown · lobby is read-only")
            }
        } catch {
            let detail = describe(error)
            note("ICLOUD: \(detail)")
            availability = .offline("iCloud unreachable · \(detail)")
        }
    }

    private func beginHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.publishPresence()
                try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
            }
        }
    }

    private func loadFriends() {
        GKLocalPlayer.local.loadFriends { [weak self] players, error in
            let ids = Set((players ?? []).map(\.gamePlayerID))
            let failure = error.map { $0 as NSError }
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.note("FRIENDS: \(self.describe(failure))") }
                self.friends = ids
            }
        }
    }

    // MARK: - Reading the lobby

    /// Keeps the lobby fresh while a screen is showing it. Runs until the
    /// task is cancelled, so hang it on a view's `.task`.
    func observe() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(Self.pollSeconds))
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // A pilot who never signed in to Game Center still gets an iCloud
        // verdict instead of a spinner that never lands.
        if availability == .checking { await checkAccount() }
        let now = Date.now
        do {
            async let pilots = records(ofType: Records.pilot, since: now.addingTimeInterval(-LobbySnapshot.staleAfter * 2))
            async let duels = records(ofType: Records.duel, since: now.addingTimeInterval(-3600))
            let tournaments = try await loadTournaments(since: now.addingTimeInterval(-7 * 86_400))
            snapshot = LobbySnapshot(
                pilots: try await pilots.compactMap(Records.pilot(from:)),
                matches: try await duels.compactMap(Records.duel(from:)),
                tournaments: tournaments
            )
            lastRefresh = now
            notice = nil
        } catch {
            let detail = describe(error)
            note("REFRESH FAILED: \(detail)")
            notice = detail
            if availability == .checking { availability = .offline(detail) }
        }
    }

    private func loadTournaments(since: Date) async throws -> [Tournament] {
        async let heads = records(ofType: Records.tournament, since: since)
        async let entries = records(ofType: Records.entry, since: since)
        async let reports = records(ofType: Records.report, since: since)
        let entriesByTournament = Dictionary(grouping: try await entries) { $0[Records.tournamentID] as? String ?? "" }
        let reportsByTournament = Dictionary(grouping: try await reports) { $0[Records.tournamentID] as? String ?? "" }
        return try await heads.compactMap { head in
            Records.tournament(
                from: head,
                entries: entriesByTournament[head.recordID.recordName] ?? [],
                reports: reportsByTournament[head.recordID.recordName] ?? []
            )
        }
    }

    private func records(ofType type: String, since: Date) async throws -> [CKRecord] {
        let query = CKQuery(recordType: type, predicate: NSPredicate(format: "%K > %@", Records.updatedAt, since as NSDate))
        var found: [CKRecord] = []
        var (results, cursor) = try await database.records(matching: query, resultsLimit: 200)
        while true {
            for (_, result) in results {
                if case let .success(record) = result { found.append(record) }
            }
            guard let next = cursor, found.count < 1000 else { break }
            (results, cursor) = try await database.records(continuingMatchFrom: next, resultsLimit: 200)
        }
        return found
    }

    // MARK: - Presence

    private func publishPresence() async {
        guard canPublish, let localID else { return }
        let record = presenceRecord ?? CKRecord(recordType: Records.pilot, recordID: CKRecord.ID(recordName: localID))
        let presence = PilotPresence(
            id: localID, name: localName, hull: localHull,
            activity: activity, matchID: currentMatchID, updatedAt: .now
        )
        Records.write(presence, into: record)
        do {
            presenceRecord = try await save(record, policy: .allKeys)
        } catch {
            let detail = describe(error)
            note("PRESENCE FAILED: \(detail)")
            notice = detail
            presenceRecord = nil
        }
    }

    // MARK: - Hosted duels

    /// The host calls this when both pilots are connected. Looks the pair up
    /// in the brackets so a tournament fixture reports itself at the end.
    func hostDuelStarted(cyanID: String, cyanName: String, orangeID: String, orangeName: String) async {
        guard canPublish, let localID else { return }
        let now = Date.now
        var brackets = snapshot.tournaments
        if let fresh = try? await loadTournaments(since: now.addingTimeInterval(-7 * 86_400)) {
            brackets = fresh
        }
        let fixture = LobbySnapshot(tournaments: brackets).fixture(between: cyanID, and: orangeID)
        let duel = LiveMatch(
            id: "\(localID)-\(Int(now.timeIntervalSince1970))",
            hostID: localID,
            cyanID: cyanID, cyanName: cyanName,
            orangeID: orangeID, orangeName: orangeName,
            fixture: fixture,
            startedAt: now, updatedAt: now
        )
        hostedDuel = duel
        hostedDuelRecord = CKRecord(recordType: Records.duel, recordID: CKRecord.ID(recordName: duel.id))
        note("DUEL: HOSTING \(cyanName) V \(orangeName)" + (fixture.map { " · FIXTURE R\($0.round + 1)" } ?? ""))
        setActivity(.playing, matchID: duel.id)
        await pushHostedDuel()
    }

    func hostDuelScored(_ score: Score) {
        guard var duel = hostedDuel else { return }
        duel.score = score
        duel.updatedAt = .now
        hostedDuel = duel
        Task { await pushHostedDuel() }
    }

    func hostDuelFinished(winner: Team, score: Score) {
        guard var duel = hostedDuel else { return }
        duel.score = score
        duel.winner = winner
        duel.phase = .finished
        duel.updatedAt = .now
        hostedDuel = duel
        note("DUEL: \(duel.name(of: winner).uppercased()) WINS \(duel.scoreline)")
        Task {
            await pushHostedDuel()
            if let fixture = duel.fixture {
                await report(fixture: fixture, winnerID: duel.playerID(of: winner), score: score)
            }
            hostedDuel = nil
            hostedDuelRecord = nil
        }
    }

    /// Any end of the duel that is not a result: a leave or a lost link.
    func hostDuelAbandoned() {
        guard hostedDuel != nil else { return }
        hostedDuel = nil
        hostedDuelRecord = nil
        note("DUEL: ABANDONED")
    }

    private func pushHostedDuel() async {
        guard let duel = hostedDuel, let record = hostedDuelRecord else { return }
        Records.write(duel, into: record)
        do {
            hostedDuelRecord = try await save(record, policy: .allKeys)
        } catch {
            let detail = describe(error)
            note("DUEL PUSH FAILED: \(detail)")
            notice = detail
        }
    }

    // MARK: - Tournaments

    func createTournament(named name: String, size: Int) async {
        guard canPublish, let localID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date.now
        let tournament = Tournament(
            id: "\(localID)-\(Int(now.timeIntervalSince1970))",
            name: trimmed.isEmpty ? "\(localName)'s Cup" : trimmed,
            organizerID: localID, size: size,
            createdAt: now, updatedAt: now
        )
        let head = CKRecord(recordType: Records.tournament, recordID: CKRecord.ID(recordName: tournament.id))
        Records.write(tournament, into: head)
        do {
            _ = try await save(head, policy: .ifServerRecordUnchanged)
            note("TOURNAMENT: CREATED \(tournament.name.uppercased()) (\(size))")
            await join(tournament)
        } catch {
            let detail = describe(error)
            note("TOURNAMENT CREATE FAILED: \(detail)")
            notice = detail
        }
    }

    func join(_ tournament: Tournament) async {
        guard canPublish, let localID else { return }
        let entry = TournamentEntrant(id: localID, name: localName, hull: localHull)
        let record = CKRecord(
            recordType: Records.entry,
            recordID: CKRecord.ID(recordName: "\(tournament.id)|\(localID)")
        )
        Records.write(entry, tournamentID: tournament.id, joinedAt: .now, into: record)
        do {
            _ = try await save(record, policy: .ifServerRecordUnchanged)
            note("TOURNAMENT: JOINED \(tournament.name.uppercased())")
        } catch let error as CKError where error.code == .serverRecordChanged {
            note("TOURNAMENT: ALREADY IN \(tournament.name.uppercased())")
        } catch {
            let detail = describe(error)
            note("TOURNAMENT JOIN FAILED: \(detail)")
            notice = detail
        }
        await refresh()
    }

    /// The organizer draws the bracket with whoever has joined so far.
    func startEarly(_ tournament: Tournament) async {
        guard canPublish, tournament.organizerID == localID, tournament.canStart else { return }
        do {
            let head = try await database.record(for: CKRecord.ID(recordName: tournament.id))
            head[Records.startedAt] = Date.now as NSDate
            head[Records.updatedAt] = Date.now as NSDate
            _ = try await save(head, policy: .ifServerRecordUnchanged)
            note("TOURNAMENT: STARTED \(tournament.name.uppercased()) WITH \(tournament.entrants.count)")
        } catch {
            let detail = describe(error)
            note("TOURNAMENT START FAILED: \(detail)")
            notice = detail
        }
        await refresh()
    }

    private func report(fixture: TournamentFixture, winnerID: String, score: Score) async {
        guard canPublish else { return }
        let record = CKRecord(
            recordType: Records.report,
            recordID: CKRecord.ID(recordName: "\(fixture.tournamentID)|r\(fixture.round)s\(fixture.slot)")
        )
        let result = TournamentResult(round: fixture.round, slot: fixture.slot, winnerID: winnerID, score: score)
        Records.write(result, tournamentID: fixture.tournamentID, reportedAt: .now, into: record)
        do {
            _ = try await save(record, policy: .ifServerRecordUnchanged)
            note("TOURNAMENT: REPORTED R\(fixture.round + 1) S\(fixture.slot + 1)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            note("TOURNAMENT: FIXTURE ALREADY REPORTED")
        } catch {
            let detail = describe(error)
            note("TOURNAMENT REPORT FAILED: \(detail)")
            notice = detail
        }
    }

    // MARK: - Invites

    /// Resolves a lobby pilot to a `GKPlayer` and hands them to Game Center
    /// matchmaking, so the inviter waits in the bay as with any other invite.
    func invite(pilotID: String, name: String, using online: OnlineMatchCoordinator) {
        note("INVITE: RESOLVING \(name.uppercased())")
        GKPlayer.loadPlayers(forIdentifiers: [pilotID]) { [weak self] players, error in
            // GameKit hands these back on its own queue; they are only ever
            // read on the main actor from here on.
            nonisolated(unsafe) let players = players
            let failure = error.map { $0 as NSError }
            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    let detail = self.describe(failure)
                    self.note("INVITE: LOOKUP FAILED \(detail)")
                    self.notice = "Could not reach \(name) · \(detail)"
                    return
                }
                guard let players, !players.isEmpty else {
                    self.note("INVITE: \(name.uppercased()) NOT FOUND")
                    self.notice = "Game Center does not know \(name)"
                    return
                }
                self.notice = nil
                online.invite(players)
            }
        }
    }

    // MARK: - Plumbing

    private func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> CKRecord {
        let (saveResults, _) = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: policy, atomically: true
        )
        guard let result = saveResults[record.recordID] else {
            throw CKError(.internalError)
        }
        return try result.get()
    }

    private func note(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        eventLog.append("\(Self.clock.string(from: .now)) \(message)")
        if eventLog.count > 12 { eventLog.removeFirst(eventLog.count - 12) }
    }

    /// Compact, readable description of a CloudKit failure: `CK<code> <NAME>`.
    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let ckError = error as? CKError {
            let name: String = switch ckError.code {
            case .notAuthenticated: "ICLOUD SIGN-IN NEEDED"
            case .networkUnavailable, .networkFailure: "NO NETWORK"
            case .serviceUnavailable: "ICLOUD UNAVAILABLE"
            case .requestRateLimited: "RATE LIMITED"
            case .quotaExceeded: "QUOTA EXCEEDED"
            case .permissionFailure: "PERMISSION DENIED"
            case .serverRecordChanged: "RECORD CHANGED"
            case .unknownItem: "SCHEMA MISSING (DEPLOY CLOUDKIT SCHEMA)"
            case .invalidArguments: "INVALID QUERY (INDEX MISSING?)"
            case .zoneBusy: "ZONE BUSY"
            case .partialFailure: "PARTIAL FAILURE"
            case .accountTemporarilyUnavailable: "ICLOUD ACCOUNT BUSY"
            default: ckError.localizedDescription.uppercased()
            }
            return "CK\(ckError.code.rawValue) \(name)"
        }
        return "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
    }
}

/// Field names and the CKRecord ↔ Core mapping. Every record type carries
/// `updatedAt` so one date-window query shape serves all of them.
private enum Records {
    static let pilot = "Pilot"
    static let duel = "Duel"
    static let tournament = "Tournament"
    static let entry = "TournamentEntry"
    static let report = "TournamentReport"

    static let updatedAt = "updatedAt"
    static let startedAt = "startedAt"
    static let tournamentID = "tournamentID"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Pilot

    static func write(_ presence: PilotPresence, into record: CKRecord) {
        record["name"] = presence.name as NSString
        record["hull"] = presence.hull.rawValue as NSString
        record["activity"] = presence.activity.rawValue as NSString
        record["matchID"] = presence.matchID.map { $0 as NSString }
        record[updatedAt] = presence.updatedAt as NSDate
    }

    static func pilot(from record: CKRecord) -> PilotPresence? {
        guard let name = record["name"] as? String,
              let hull = (record["hull"] as? String).flatMap(Hull.init(rawValue:)),
              let activity = (record["activity"] as? String).flatMap(PilotActivity.init(rawValue:)),
              let updated = record[updatedAt] as? Date else { return nil }
        return PilotPresence(
            id: record.recordID.recordName, name: name, hull: hull,
            activity: activity, matchID: record["matchID"] as? String, updatedAt: updated
        )
    }

    // MARK: Duel

    static func write(_ duel: LiveMatch, into record: CKRecord) {
        record["hostID"] = duel.hostID as NSString
        record["cyanID"] = duel.cyanID as NSString
        record["cyanName"] = duel.cyanName as NSString
        record["orangeID"] = duel.orangeID as NSString
        record["orangeName"] = duel.orangeName as NSString
        record["cyanScore"] = duel.score.cyan as NSNumber
        record["orangeScore"] = duel.score.orange as NSNumber
        record["phase"] = duel.phase.rawValue as NSString
        record["winner"] = duel.winner.map { $0.rawValue as NSString }
        record["fixtureTournamentID"] = duel.fixture.map { $0.tournamentID as NSString }
        record["fixtureRound"] = duel.fixture.map { $0.round as NSNumber }
        record["fixtureSlot"] = duel.fixture.map { $0.slot as NSNumber }
        record[startedAt] = duel.startedAt as NSDate
        record[updatedAt] = duel.updatedAt as NSDate
    }

    static func duel(from record: CKRecord) -> LiveMatch? {
        guard let hostID = record["hostID"] as? String,
              let cyanID = record["cyanID"] as? String,
              let cyanName = record["cyanName"] as? String,
              let orangeID = record["orangeID"] as? String,
              let orangeName = record["orangeName"] as? String,
              let cyanScore = record["cyanScore"] as? Int,
              let orangeScore = record["orangeScore"] as? Int,
              let phase = (record["phase"] as? String).flatMap(MatchPhase.init(rawValue:)),
              let started = record[startedAt] as? Date,
              let updated = record[updatedAt] as? Date else { return nil }
        var fixture: TournamentFixture?
        if let tournamentID = record["fixtureTournamentID"] as? String,
           let round = record["fixtureRound"] as? Int,
           let slot = record["fixtureSlot"] as? Int {
            fixture = TournamentFixture(tournamentID: tournamentID, round: round, slot: slot)
        }
        return LiveMatch(
            id: record.recordID.recordName, hostID: hostID,
            cyanID: cyanID, cyanName: cyanName, orangeID: orangeID, orangeName: orangeName,
            score: Score(cyan: cyanScore, orange: orangeScore), phase: phase,
            winner: (record["winner"] as? String).flatMap(Team.init(rawValue:)),
            fixture: fixture, startedAt: started, updatedAt: updated
        )
    }

    // MARK: Tournament

    static func write(_ tournament: Tournament, into record: CKRecord) {
        record["name"] = tournament.name as NSString
        record["organizerID"] = tournament.organizerID as NSString
        record["size"] = tournament.size as NSNumber
        record["createdAt"] = tournament.createdAt as NSDate
        record[startedAt] = tournament.startedAt.map { $0 as NSDate }
        record[updatedAt] = tournament.updatedAt as NSDate
    }

    static func write(_ entrant: TournamentEntrant, tournamentID: String, joinedAt: Date, into record: CKRecord) {
        record[Records.tournamentID] = tournamentID as NSString
        record["playerID"] = entrant.id as NSString
        record["name"] = entrant.name as NSString
        record["hull"] = entrant.hull.rawValue as NSString
        record[updatedAt] = joinedAt as NSDate
    }

    static func write(_ result: TournamentResult, tournamentID: String, reportedAt: Date, into record: CKRecord) {
        record[Records.tournamentID] = tournamentID as NSString
        record["round"] = result.round as NSNumber
        record["slot"] = result.slot as NSNumber
        record["winnerID"] = result.winnerID as NSString
        record["cyanScore"] = result.score.cyan as NSNumber
        record["orangeScore"] = result.score.orange as NSNumber
        record[updatedAt] = reportedAt as NSDate
    }

    /// Rebuilds a tournament from its head record and the entry and report
    /// records other pilots wrote. Joins and reports replay through the Core
    /// rules in time order, so a late joiner or a duplicate report is dropped
    /// here exactly as it would have been on the organizer's device.
    static func tournament(from head: CKRecord, entries: [CKRecord], reports: [CKRecord]) -> Tournament? {
        guard let name = head["name"] as? String,
              let organizerID = head["organizerID"] as? String,
              let size = head["size"] as? Int,
              let createdAt = head["createdAt"] as? Date,
              let updated = head[updatedAt] as? Date else { return nil }
        let startedEarly = head[startedAt] as? Date

        var tournament = Tournament(
            id: head.recordID.recordName, name: name, organizerID: organizerID, size: size,
            createdAt: createdAt, updatedAt: updated
        )
        let joins: [(TournamentEntrant, Date)] = entries.compactMap { record in
            guard let playerID = record["playerID"] as? String,
                  let name = record["name"] as? String,
                  let hull = (record["hull"] as? String).flatMap(Hull.init(rawValue:)),
                  let joinedAt = record[updatedAt] as? Date else { return nil }
            return (TournamentEntrant(id: playerID, name: name, hull: hull), joinedAt)
        }
        // The organizer is seed one whatever the clocks say.
        for (entrant, joinedAt) in joins.sorted(by: { lhs, rhs in
            if (lhs.0.id == organizerID) != (rhs.0.id == organizerID) { return lhs.0.id == organizerID }
            return lhs.1 < rhs.1
        }) {
            if let startedEarly, joinedAt > startedEarly { continue }
            tournament.join(entrant, at: joinedAt)
        }
        if let startedEarly, !tournament.hasStarted {
            tournament.start(by: organizerID, at: startedEarly)
        }

        let results: [(TournamentResult, Date)] = reports.compactMap { record in
            guard let round = record["round"] as? Int,
                  let slot = record["slot"] as? Int,
                  let winnerID = record["winnerID"] as? String,
                  let cyan = record["cyanScore"] as? Int,
                  let orange = record["orangeScore"] as? Int,
                  let reportedAt = record[updatedAt] as? Date else { return nil }
            return (TournamentResult(round: round, slot: slot, winnerID: winnerID, score: Score(cyan: cyan, orange: orange)), reportedAt)
        }
        // Earlier rounds first so a final can only land once its semis have.
        for (result, reportedAt) in results.sorted(by: { ($0.0.round, $0.1) < ($1.0.round, $1.1) }) {
            tournament.report(result, at: reportedAt)
        }
        return tournament
    }
}
