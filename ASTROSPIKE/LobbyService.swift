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
    /// The `GKPlayer` objects Game Center has already handed us (friends and
    /// recent opponents), keyed by gamePlayerID. Inviting one of these skips
    /// the identifier lookup, which returns nothing for some accounts.
    private var knownPlayers: [String: GKPlayer] = [:]
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

    /// Every standing invite either end of this pilot can see, rebuilt on
    /// each refresh. Empty when the lobby is unreachable, which reads as
    /// "no invites" rather than a stuck spinner.
    private(set) var inviteBook = StandingInviteBook()
    /// Standing invites this pilot has answered on this device, so a reply
    /// that has not round-tripped through CloudKit yet still clears the row.
    private var answeredLocally: Set<String> = []

    /// The duel this pilot is hosting, mirrored to CloudKit as the score moves.
    private(set) var hostedDuel: LiveMatch?
    private var hostedDuelRecord: CKRecord?
    private var presenceRecord: CKRecord?

    /// CloudKit is resolved on first use, never at construction.
    ///
    /// `CKContainer(identifier:)` raises rather than throws when the app holds
    /// no entitlement for that container, and an unsigned build has no
    /// entitlements at all — so building it in a stored property took the whole
    /// process down at launch instead of merely costing us the lobby. Every
    /// other CloudKit call already sits behind `start()`, which returns early
    /// without a signed-in pilot, so deferring this one keeps CloudKit out of a
    /// build that can never reach it.
    ///
    /// Ignored by observation: nothing renders it, and the accessor below
    /// assigns it from a getter SwiftUI may call mid-update.
    @ObservationIgnored private var resolvedContainer: CKContainer?

    private var container: CKContainer {
        if let resolvedContainer { return resolvedContainer }
        let made = CKContainer(identifier: Self.containerIdentifier)
        resolvedContainer = made
        return made
    }

    private var database: CKDatabase { container.publicCloudDatabase }
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
            availability = .offline(playerFacing(error))
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

    private func loadFriends(completion: (@MainActor () -> Void)? = nil) {
        GKLocalPlayer.local.loadFriends { [weak self] players, error in
            nonisolated(unsafe) let players = players
            let failure = error.map { $0 as NSError }
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.note("FRIENDS: \(self.describe(failure))") }
                let friends = players ?? []
                self.friends = Set(friends.map(\.gamePlayerID))
                for player in friends { self.knownPlayers[player.gamePlayerID] = player }
                self.note("FRIENDS: \(friends.count) KNOWN")
                completion?()
            }
        }
        GKLocalPlayer.local.loadRecentPlayers { [weak self] players, _ in
            nonisolated(unsafe) let players = players
            Task { @MainActor in
                guard let self else { return }
                for player in players ?? [] { self.knownPlayers[player.gamePlayerID] = player }
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
            // A standing invite outlives every other record here, so its
            // window is its own lifetime plus a margin rather than the hour
            // a duel gets -- read it any narrower and yesterday's ask, which
            // is the entire point of the feature, is invisible.
            let inviteWindow = now.addingTimeInterval(-(StandingInviteBook.lifetime + 3600))
            async let invites = records(ofType: Records.standingInvite, since: inviteWindow)
            async let inviteReplies = records(ofType: Records.inviteReply, since: inviteWindow)
            let tournaments = try await loadTournaments(since: now.addingTimeInterval(-7 * 86_400))
            let book = StandingInviteBook(
                invites: try await invites.compactMap(Records.standingInvite(from:)),
                replies: try await inviteReplies.compactMap(Records.inviteReply(from:))
            )
            // Only from the second poll on: on the first, every waiting ask
            // is "new", and a pilot opening the lobby would get a burst of
            // INVITE WAITING lines for invites that arrived yesterday.
            if lastRefresh != nil { noteInviteChanges(from: inviteBook, to: book, at: now) }
            inviteBook = book
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
            notice = playerFacing(error)
            if availability == .checking { availability = .offline(playerFacing(error)) }
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
        var results: [(CKRecord.ID, Result<CKRecord, Error>)]
        var cursor: CKQueryOperation.Cursor?
        do {
            (results, cursor) = try await database.records(matching: query, resultsLimit: 200)
        } catch let error as CKError where error.code == .unknownItem {
            // The record type does not exist in this environment yet. In
            // development the first save creates it; in production the
            // schema has to be imported (CloudKit/ASTROSPIKE.ckdb). Either
            // way an empty board beats a red banner on every poll.
            return []
        }
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
            notice = playerFacing(error)
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
            notice = playerFacing(error)
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
            notice = playerFacing(error)
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
            notice = playerFacing(error)
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
            notice = playerFacing(error)
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
            notice = playerFacing(error)
        }
    }

    // MARK: - Invites

    /// Resolves a lobby pilot to a `GKPlayer` and hands them to Game Center
    /// matchmaking, so the inviter waits in the bay as with any other invite.
    func invite(pilotID: String, name: String, using online: OnlineMatchCoordinator) {
        if let player = knownPlayers[pilotID] {
            note("INVITE: \(name.uppercased()) FROM FRIEND LIST")
            notice = nil
            online.invite([player])
            return
        }
        note("INVITE: RESOLVING \(name.uppercased()) \(pilotID.prefix(6))… (\(knownPlayers.count) KNOWN)")
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
                    self.notice = "Could not reach \(name). Try again."
                    return
                }
                guard let players, !players.isEmpty else {
                    self.note("INVITE: LOOKUP EMPTY FOR \(name.uppercased()), RELOADING FRIENDS")
                    // The identifier lookup comes back empty for some accounts
                    // even when the pilot is a friend. Refresh the friend list
                    // and try once more from there before giving up.
                    self.loadFriends { [weak self] in
                        guard let self else { return }
                        if let player = self.knownPlayers[pilotID] {
                            self.note("INVITE: \(name.uppercased()) FOUND ON RELOAD")
                            self.notice = nil
                            online.invite([player])
                        } else {
                            self.note("INVITE: \(name.uppercased()) NOT IN \(self.friends.count) FRIENDS")
                            self.notice = self.friends.isEmpty
                                ? "Allow Game Center friend access in Settings › \(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ASTROSPIKE") to invite \(name)"
                                : "\(name) is not on your Game Center friend list. Add them there, or invite from the bay."
                        }
                    }
                    return
                }
                self.notice = nil
                online.invite(players)
            }
        }
    }

    // MARK: - Standing invites

    /// Invites a pilot for whenever they are next free, as well as right now.
    ///
    /// A Game Center invitation only exists while the pilot who sent it is
    /// sitting in matchmaking, so an opponent who is asleep, at work, or
    /// simply not holding their phone never sees it. This writes the ask
    /// down first, so it survives both apps closing; the live invite that
    /// follows is the optimistic case, not the only one.
    func inviteAnytime(pilotID: String, name: String, using online: OnlineMatchCoordinator) {
        // Durable first, live second, in that order and not concurrently.
        // Both paths report failure through `notice`, and the ask that
        // keeps is the one Ian asked for -- it must not have its message
        // overwritten by the optimistic invite that may not have been
        // wanted anyway.
        Task { [weak self] in
            await self?.openStandingInvite(pilotID: pilotID, name: name)
            self?.invite(pilotID: pilotID, name: name, using: online)
        }
    }

    /// Writes (or refreshes) the durable ask. The record name is fixed per
    /// pair, so asking twice moves the clock forward instead of stacking a
    /// second row on the other pilot's screen.
    func openStandingInvite(pilotID: String, name: String) async {
        guard canPublish, let localID else {
            note("STANDING INVITE: NOT PUBLISHED · \(availability.label)")
            return
        }
        let now = Date.now
        let invite = StandingInvite(
            id: StandingInvite.id(hostID: localID, guestID: pilotID),
            hostID: localID,
            hostName: localName,
            hostHull: localHull,
            guestID: pilotID,
            guestName: name,
            createdAt: now,
            expiresAt: inviteBook.expiry(from: now)
        )
        let record = CKRecord(recordType: Records.standingInvite, recordID: CKRecord.ID(recordName: invite.id))
        Records.write(invite, into: record)
        do {
            _ = try await save(record, policy: .allKeys)
            note("STANDING INVITE → \(name.uppercased()) · KEEPS 24H")
            // A fresh ask supersedes whatever the last one was answered, so
            // drop the stale reply rather than leaving the row pre-declined.
            answeredLocally.remove(invite.id)
            await refresh()
        } catch {
            let detail = describe(error)
            note("STANDING INVITE FAILED: \(detail)")
            notice = playerFacing(error)
        }
    }

    /// Takes an unanswered ask back. Only the host can: it is their record.
    func withdrawStandingInvite(_ invite: StandingInvite) async {
        guard canPublish, invite.hostID == localID else { return }
        let record = CKRecord(recordType: Records.standingInvite, recordID: CKRecord.ID(recordName: invite.id))
        var pulled = invite
        pulled.withdrawn = true
        Records.write(pulled, into: record)
        do {
            _ = try await save(record, policy: .allKeys)
            note("STANDING INVITE WITHDRAWN · \(invite.guestName.uppercased())")
            await refresh()
        } catch {
            note("WITHDRAW FAILED: \(describe(error))")
            notice = playerFacing(error)
        }
    }

    /// Answers an ask addressed to this pilot.
    ///
    /// Accepting sends the live Game Center invitation **back to the host**,
    /// rather than waiting for the host's device to notice and send one out.
    /// That is deliberate: GameKit delivers an invite as a push, so the
    /// pilot who originally asked can have had the app closed all day and
    /// still get tapped on the shoulder. Nothing had to keep running, and
    /// nothing fires without a pilot on one end pressing a button.
    func answerStandingInvite(
        _ invite: StandingInvite,
        accept: Bool,
        using online: OnlineMatchCoordinator
    ) {
        guard let localID, invite.guestID == localID else { return }
        // Clear the row now. The write below may be slow or may fail on a
        // read-only lobby, and either way the pilot has answered.
        answeredLocally.insert(invite.id)
        note("STANDING INVITE \(accept ? "ACCEPTED" : "DECLINED") · \(invite.hostName.uppercased())")
        if accept { self.invite(pilotID: invite.hostID, name: invite.hostName, using: online) }
        Task { await publishReply(to: invite, accepted: accept) }
    }

    private func publishReply(to invite: StandingInvite, accepted: Bool) async {
        guard canPublish, let localID else { return }
        let reply = StandingInviteReply(
            inviteID: invite.id, guestID: localID, accepted: accepted, repliedAt: .now
        )
        let record = CKRecord(recordType: Records.inviteReply, recordID: CKRecord.ID(recordName: reply.id))
        Records.write(reply, into: record)
        do {
            _ = try await save(record, policy: .allKeys)
            await refresh()
        } catch {
            // Deliberately put the row back. `answeredLocally` is in-memory
            // and optimistic: it exists so the row clears the instant the
            // pilot taps, not to remember an answer the host never got. An
            // unsent reply is an unanswered invite, and the ask should be
            // there to answer again rather than silently swallowed.
            answeredLocally.remove(invite.id)
            note("REPLY FAILED: \(describe(error)) · ASK IS BACK")
            notice = playerFacing(error)
        }
    }

    /// Asks pointed at this pilot that still want an answer.
    var standingInviteInbox: [StandingInvite] {
        guard let localID else { return [] }
        return inviteBook.inbox(for: localID, at: .now)
            .filter { !answeredLocally.contains($0.id) }
    }

    /// Asks this pilot has out that nobody has answered yet.
    var standingInviteOutbox: [StandingInvite] {
        guard let localID else { return [] }
        return inviteBook.outbox(from: localID, at: .now)
    }

    func hasStandingInvite(to pilotID: String) -> Bool {
        guard let localID else { return false }
        return inviteBook.hasOpenInvite(from: localID, to: pilotID, at: .now)
    }

    /// Says out loud what changed between two polls, so the log reads as a
    /// story rather than a snapshot: a new ask arriving, one being answered.
    private func noteInviteChanges(from old: StandingInviteBook, to new: StandingInviteBook, at now: Date) {
        guard let localID else { return }
        let seen = Set(old.inbox(for: localID, at: now).map(\.id))
        for arrival in new.inbox(for: localID, at: now) where !seen.contains(arrival.id) {
            note("INVITE WAITING FROM \(arrival.hostName.uppercased())")
        }
        let settledBefore = Set(old.answers(for: localID, at: now).map(\.invite.id))
        for (invite, status) in new.answers(for: localID, at: now) where !settledBefore.contains(invite.id) {
            note("\(invite.guestName.uppercased()) \(status.label) YOUR INVITE")
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

    /// What a pilot sees. Schema and index names stay in `describe`.
    private func playerFacing(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return PlayerNetworkCopy.CloudKit.other.message
        }
        let kind: PlayerNetworkCopy.CloudKit = switch ckError.code {
        case .notAuthenticated: .notAuthenticated
        case .networkUnavailable, .networkFailure: .network
        case .serviceUnavailable, .accountTemporarilyUnavailable: .unavailable
        case .unknownItem: .unknownItem
        case .invalidArguments: .invalidArguments
        case .quotaExceeded: .quotaExceeded
        case .permissionFailure: .permissionFailure
        default: .other
        }
        return kind.message
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
    static let standingInvite = "StandingInvite"
    static let inviteReply = "StandingInviteReply"

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

    // MARK: Standing invites

    static func write(_ invite: StandingInvite, into record: CKRecord) {
        record["hostID"] = invite.hostID as NSString
        record["hostName"] = invite.hostName as NSString
        record["hostHull"] = invite.hostHull.rawValue as NSString
        record["guestID"] = invite.guestID as NSString
        record["guestName"] = invite.guestName as NSString
        record[startedAt] = invite.createdAt as NSDate
        record["expiresAt"] = invite.expiresAt as NSDate
        record["withdrawn"] = (invite.withdrawn ? 1 : 0) as NSNumber
        // Every record type in the lobby carries `updatedAt` so one window
        // query shape serves all of them, and `refresh()` filters on it.
        // These two dates must stay separate: `startedAt` is when the ask
        // was made and decides its 24-hour life, while `updatedAt` is when
        // the record last moved. Collapse them and a withdrawal made on a
        // day-old invite would land outside the query window, so the guest
        // would go on seeing an ask the host had already taken back.
        record[updatedAt] = Date.now as NSDate
    }

    static func standingInvite(from record: CKRecord) -> StandingInvite? {
        guard let hostID = record["hostID"] as? String,
              let hostName = record["hostName"] as? String,
              let guestID = record["guestID"] as? String,
              let guestName = record["guestName"] as? String,
              let createdAt = record[startedAt] as? Date,
              let expiresAt = record["expiresAt"] as? Date else { return nil }
        return StandingInvite(
            id: record.recordID.recordName,
            hostID: hostID,
            hostName: hostName,
            hostHull: (record["hostHull"] as? String).flatMap(Hull.init(rawValue:)) ?? .lancet,
            guestID: guestID,
            guestName: guestName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            withdrawn: (record["withdrawn"] as? Int ?? 0) != 0
        )
    }

    static func write(_ reply: StandingInviteReply, into record: CKRecord) {
        record["inviteID"] = reply.inviteID as NSString
        record["guestID"] = reply.guestID as NSString
        record["accepted"] = (reply.accepted ? 1 : 0) as NSNumber
        record[updatedAt] = reply.repliedAt as NSDate
    }

    static func inviteReply(from record: CKRecord) -> StandingInviteReply? {
        guard let inviteID = record["inviteID"] as? String,
              let guestID = record["guestID"] as? String,
              let accepted = record["accepted"] as? Int,
              let repliedAt = record[updatedAt] as? Date else { return nil }
        return StandingInviteReply(
            inviteID: inviteID, guestID: guestID, accepted: accepted != 0, repliedAt: repliedAt
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
