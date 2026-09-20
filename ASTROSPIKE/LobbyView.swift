import SwiftUI
import ASTROSPIKECore
@preconcurrency import GameKit

/// Who is flying right now, the duels in progress with their scores, and the
/// tournaments taking entrants or underway. Every row that looks tappable is.
struct LobbyView: View {
    let lobby: LobbyService
    let online: OnlineMatchCoordinator
    @State private var newTournamentName = ""
    @State private var newTournamentSize = 4
    @State private var isShowingLog = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                invitesSection
                onlineSection
                anytimeSection
                duelsSection
                tournamentsSection
                createSection
            }
            .navigationTitle("LOBBY")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await lobby.refresh() }
            .sheet(isPresented: $isShowingLog) {
                LinkLogView(
                    transcript: online.linkTranscript(lobbyEvents: lobby.eventLog),
                    events: online.eventLog
                )
            }
            .navigationDestination(for: String.self) { tournamentID in
                TournamentDetailView(tournamentID: tournamentID, lobby: lobby, online: online)
            }
        }
        .task { await lobby.observe() }
        .task { online.loadInvitees() }
        .accessibilityIdentifier("lobby-screen")
    }

    private var now: Date { .now }
    private var localID: String { lobby.localID ?? "" }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lobby.availability.label)
                        .font(.caption2.monospaced().weight(.bold)).tracking(1.5)
                    Text("\(lobby.localName.uppercased()) · \(lobby.activity.label)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if lobby.isRefreshing { ProgressView() }
            }
            // The link log is two taps from the lobby on purpose. Every
            // multiplayer defect so far has been found on hardware with no
            // debugger attached, and "what did it say?" is the first
            // question every time.
            Button { isShowingLog = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                    Text(online.statusLabel)
                        .font(.caption2.monospaced().weight(.bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text("LINK LOG · \(online.eventLog.count)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lobby-link-log")
            if let notice = lobby.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("lobby-notice")
            }
        }
    }

    private var statusColor: Color {
        switch lobby.availability {
        case .live: .green
        case .checking: .yellow
        case .readOnly: .orange
        case .offline: .red
        }
    }

    private var onlineSection: some View {
        let pilots = lobby.snapshot.onlinePilots(at: now, friends: lobby.friends, excluding: localID)
        return Section("ONLINE NOW · \(pilots.count)") {
            if pilots.isEmpty {
                Text(lobby.lastRefresh == nil ? "Looking around…" : "Nobody else is flying right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(pilots) { pilot in
                PilotRow(
                    pilot: pilot,
                    isFriend: lobby.friends.contains(pilot.id),
                    // Guests never learn the duel's ID, so fall back to any
                    // live duel that has them in it.
                    duel: pilot.matchID.flatMap { id in lobby.snapshot.matches.first { $0.id == id } }
                        ?? lobby.snapshot.liveMatches(at: now).first { $0.involves(pilot.id) },
                    isInvited: lobby.hasStandingInvite(to: pilot.id)
                ) {
                    lobby.inviteAnytime(pilotID: pilot.id, name: pilot.name, using: online)
                }
            }
        }
        .accessibilityIdentifier("lobby-online")
    }

    /// Asks waiting on this pilot, and asks this pilot has out.
    ///
    /// A Game Center invitation lives only while the pilot who sent it is
    /// sitting in matchmaking, so the ordinary way to arrange a duel with
    /// somebody who has a job is to miss each other all day. These rows are
    /// the durable version: Ian asks once, and Maya answers whenever she
    /// next opens the app.
    @ViewBuilder
    private var invitesSection: some View {
        let inbox = lobby.standingInviteInbox
        let outbox = lobby.standingInviteOutbox
        if !inbox.isEmpty || !outbox.isEmpty {
            Section("INVITES · \(inbox.count + outbox.count)") {
                ForEach(inbox) { invite in
                    StandingInviteRow(invite: invite, isWaitingOnMe: true) {
                        lobby.answerStandingInvite(invite, accept: true, using: online)
                    } decline: {
                        lobby.answerStandingInvite(invite, accept: false, using: online)
                    }
                }
                ForEach(outbox) { invite in
                    StandingInviteRow(invite: invite, isWaitingOnMe: false) {} decline: {
                        Task { await lobby.withdrawStandingInvite(invite) }
                    }
                }
            }
            .accessibilityIdentifier("lobby-invites")
        }
    }

    /// Everyone Game Center will let this pilot reach who is *not* in the
    /// lobby right now. Inviting one of these is the whole point of a
    /// standing invite: nobody has to already be here.
    @ViewBuilder
    private var anytimeSection: some View {
        let present = Set(lobby.snapshot.onlinePilots(at: now, friends: lobby.friends, excluding: localID).map(\.id))
        let pending = Set(lobby.standingInviteOutbox.map(\.guestID))
        let away = online.invitees.filter { !present.contains($0.gamePlayerID) && !pending.contains($0.gamePlayerID) }
        Section("INVITE ANYTIME · \(away.count)") {
            Text("They do not have to be here. The ask keeps for a day, and they join when they open the app.")
                .font(.caption).foregroundStyle(.secondary)
            if away.isEmpty {
                Text(online.isLoadingInvitees ? "Loading friends…" : "No Game Center friends or recent opponents yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(away, id: \.gamePlayerID) { player in
                Button {
                    lobby.inviteAnytime(pilotID: player.gamePlayerID, name: player.displayName, using: online)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.title3).foregroundStyle(.secondary)
                        Text(player.displayName).font(.headline)
                        Spacer()
                        Label("ASK", systemImage: "paperplane")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lobby-anytime-\(player.gamePlayerID)")
            }
        }
        .accessibilityIdentifier("lobby-anytime")
    }

    private var duelsSection: some View {
        let live = lobby.snapshot.liveMatches(at: now)
        let recent = lobby.snapshot.recentResults()
        return Section("LIVE DUELS · \(live.count)") {
            if live.isEmpty, recent.isEmpty {
                Text("No duels in the air.").foregroundStyle(.secondary)
            }
            ForEach(live) { duel in DuelCard(duel: duel, now: now) }
            ForEach(recent) { duel in DuelCard(duel: duel, now: now).opacity(0.62) }
        }
        .accessibilityIdentifier("lobby-duels")
    }

    private var tournamentsSection: some View {
        let tournaments = lobby.snapshot.visibleTournaments(for: localID)
        return Section("TOURNAMENTS · \(tournaments.count)") {
            if tournaments.isEmpty {
                Text("No brackets open. Start one below.").foregroundStyle(.secondary)
            }
            ForEach(tournaments) { tournament in
                NavigationLink(value: tournament.id) {
                    TournamentRow(tournament: tournament, localID: localID)
                }
                .accessibilityIdentifier("lobby-tournament-\(tournament.id)")
            }
        }
        .accessibilityIdentifier("lobby-tournaments")
    }

    private var createSection: some View {
        Section {
            TextField("Name (optional)", text: $newTournamentName)
                .textInputAutocapitalization(.words)
            Picker("Bracket", selection: $newTournamentSize) {
                ForEach(Tournament.allowedSizes, id: \.self) { size in
                    Text("\(size) PILOTS").tag(size)
                }
            }
            .pickerStyle(.segmented)
            Button {
                let name = newTournamentName, size = newTournamentSize
                newTournamentName = ""
                Task { await lobby.createTournament(named: name, size: size) }
            } label: {
                Label("Create bracket", systemImage: "trophy.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!lobby.canPublish)
            .accessibilityIdentifier("lobby-create-tournament")
        } header: {
            Text("NEW TOURNAMENT")
        } footer: {
            Text(lobby.canPublish
                 ? "Single elimination. Friends join from this list; the organizer can start short and byes fill the gaps."
                 : "Sign in to iCloud to create or join a bracket.")
        }
    }
}

// MARK: - Rows

private struct PilotRow: View {
    let pilot: PilotPresence
    let isFriend: Bool
    let duel: LiveMatch?
    /// An ask is already out to this pilot: say so rather than sending a
    /// second one that only resets their clock.
    let isInvited: Bool
    let invite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HullBadge(hull: pilot.hull, team: .cyan).frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(pilot.name).font(.headline)
                    if isFriend {
                        Text("FRIEND").font(.caption2.monospaced().weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.cyan.opacity(0.18), in: Capsule())
                            .foregroundStyle(.cyan)
                    }
                }
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if pilot.activity == .playing {
                Text("LIVE").font(.caption2.monospaced().weight(.bold)).foregroundStyle(.orange)
            } else if isInvited {
                Text("WAITING").font(.caption2.monospaced().weight(.bold)).foregroundStyle(.cyan)
                    .accessibilityIdentifier("lobby-pilot-waiting-\(pilot.id)")
            } else {
                Button(action: invite) {
                    Label("INVITE", systemImage: "paperplane.fill")
                        .font(.caption.weight(.bold)).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .accessibilityLabel("Invite \(pilot.name)")
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("lobby-pilot-\(pilot.id)")
    }

    private var detail: String {
        if pilot.activity == .playing, let duel {
            let opponent = duel.cyanID == pilot.id ? duel.orangeName : duel.cyanName
            return "VS \(opponent.uppercased()) · \(duel.scoreline)"
        }
        return pilot.activity.label
    }
}

/// One standing invite, from whichever end is looking at it.
private struct StandingInviteRow: View {
    let invite: StandingInvite
    let isWaitingOnMe: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HullBadge(hull: invite.hostHull, team: isWaitingOnMe ? .orange : .cyan)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(isWaitingOnMe ? invite.hostName : invite.guestName).font(.headline)
                Text(isWaitingOnMe ? "WANTS A DUEL · \(remaining)" : "ASKED · \(remaining)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if isWaitingOnMe {
                Button(action: accept) {
                    Label("JOIN", systemImage: "bolt.horizontal.fill")
                        .font(.caption.weight(.bold)).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .accessibilityIdentifier("invite-join-\(invite.id)")
                Button(action: decline) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered).tint(.secondary)
                .accessibilityLabel("Decline invite from \(invite.hostName)")
                .accessibilityIdentifier("invite-decline-\(invite.id)")
            } else {
                Button(action: decline) {
                    Text("WITHDRAW").font(.caption2.monospaced().weight(.bold))
                }
                .buttonStyle(.bordered).tint(.secondary)
                .accessibilityIdentifier("invite-withdraw-\(invite.id)")
            }
        }
        // Both buttons live here, so the row is a container rather than one
        // big tap target that would swallow whichever one it covered.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lobby-invite-\(invite.id)")
    }

    /// "KEEPS 6H" reads better than an expiry timestamp on a row somebody
    /// glances at, and it is the number that decides whether to answer now.
    private var remaining: String {
        let seconds = Int(invite.expiresAt.timeIntervalSinceNow)
        guard seconds > 0 else { return "EXPIRED" }
        if seconds >= 3600 { return "KEEPS \(seconds / 3600)H" }
        return "KEEPS \(max(1, seconds / 60))M"
    }
}

/// A scoreboard for one duel. Live ones tick; finished ones name the winner.
private struct DuelCard: View {
    let duel: LiveMatch
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            side(name: duel.cyanName, score: duel.score.cyan, team: .cyan, alignment: .leading)
            Text(duel.scoreline)
                .font(.title3.monospaced().weight(.black))
                .frame(minWidth: 72)
            side(name: duel.orangeName, score: duel.score.orange, team: .orange, alignment: .trailing)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if duel.isLive {
                    Text("LIVE").foregroundStyle(.green)
                    Text(elapsed).foregroundStyle(.secondary)
                } else {
                    Text("FINAL").foregroundStyle(.secondary)
                    if let winner = duel.winner {
                        Text(duel.name(of: winner).uppercased())
                            .foregroundStyle(winner == .cyan ? .cyan : .orange)
                            .lineLimit(1)
                    }
                }
            }
            .font(.caption2.monospaced().weight(.bold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(duel.cyanName) \(duel.score.cyan), \(duel.orangeName) \(duel.score.orange), \(duel.isLive ? "live" : "final")")
        .accessibilityIdentifier("lobby-duel-\(duel.id)")
    }

    private func side(name: String, score: Int, team: Team, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(name).font(.subheadline.weight(.bold)).lineLimit(1)
            Text(team == .cyan ? "CYAN" : "ORANGE")
                .font(.caption2.monospaced()).foregroundStyle(team == .cyan ? .cyan : .orange)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(duel.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TournamentRow: View {
    let tournament: Tournament
    let localID: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy.fill").foregroundStyle(.yellow).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tournament.name).font(.headline)
                Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(tournament.status.label)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(tournament.status == .open ? .green : .orange)
        }
    }

    private var subtitle: String {
        var parts = ["\(tournament.entrants.count)/\(tournament.size) PILOTS", "BY \(tournament.organizerName.uppercased())"]
        if tournament.isEntered(localID) {
            if let next = tournament.bracket.nextPairing(for: localID),
               let opponent = next.opponent(of: localID),
               let name = tournament.entrants.first(where: { $0.id == opponent })?.name {
                parts.append("YOU V \(name.uppercased())")
            } else if tournament.bracket.champion == localID {
                parts.append("YOU WON")
            } else if tournament.bracket.isEliminated(localID) {
                parts.append("YOU ARE OUT")
            } else if tournament.hasStarted {
                parts.append("WAITING ON A RESULT")
            } else {
                parts.append("YOU ARE IN")
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tournament detail

private struct TournamentDetailView: View {
    let tournamentID: String
    let lobby: LobbyService
    let online: OnlineMatchCoordinator

    private var tournament: Tournament? {
        lobby.snapshot.tournaments.first { $0.id == tournamentID }
    }

    var body: some View {
        Group {
            if let tournament {
                content(for: tournament)
            } else {
                ContentUnavailableView("Bracket gone", systemImage: "trophy", description: Text("It is no longer in the lobby."))
            }
        }
        .navigationTitle(tournament?.name.uppercased() ?? "BRACKET")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tournament-detail")
    }

    private func content(for tournament: Tournament) -> some View {
        let localID = lobby.localID ?? ""
        let names = Dictionary(tournament.entrants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return List {
            Section {
                HStack {
                    Text(tournament.status.label).font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(tournament.status == .open ? .green : .orange)
                    Spacer()
                    Text("\(tournament.entrants.count)/\(tournament.size) PILOTS · BY \(tournament.organizerName.uppercased())")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let champion = tournament.bracket.champion {
                    Label("\(names[champion, default: "?"].uppercased()) TAKES THE CUP", systemImage: "crown.fill")
                        .font(.headline).foregroundStyle(.yellow)
                }
                actions(for: tournament, localID: localID, names: names)
            }
            Section("BRACKET") {
                BracketView(bracket: tournament.bracket, names: names, localID: localID)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            Section("PILOTS") {
                ForEach(Array(tournament.entrants.enumerated()), id: \.element.id) { index, entrant in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.caption.monospaced().bold()).foregroundStyle(.secondary).frame(width: 18)
                        HullBadge(hull: entrant.hull, team: .cyan).frame(width: 28, height: 32)
                        Text(entrant.name).font(.subheadline.weight(entrant.id == localID ? .bold : .regular))
                        if entrant.id == tournament.organizerID {
                            Text("HOST").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for tournament: Tournament, localID: String, names: [String: String]) -> some View {
        if !tournament.hasStarted, !tournament.isEntered(localID), !tournament.isFull {
            Button {
                Task { await lobby.join(tournament) }
            } label: {
                Label("Join bracket", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .disabled(!lobby.canPublish)
            .accessibilityIdentifier("tournament-join")
        }
        if tournament.organizerID == localID, tournament.canStart {
            Button {
                Task { await lobby.startEarly(tournament) }
            } label: {
                Label("Start now with \(tournament.entrants.count)", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityIdentifier("tournament-start")
        }
        if tournament.status == .underway,
           let next = tournament.bracket.nextPairing(for: localID),
           let opponentID = next.opponent(of: localID) {
            let opponent = names[opponentID, default: "?"]
            VStack(alignment: .leading, spacing: 8) {
                Text(next.inviterID == localID
                     ? "YOUR FIXTURE · INVITE \(opponent.uppercased())"
                     : "YOUR FIXTURE · \(opponent.uppercased()) INVITES YOU")
                    .font(.caption2.monospaced().weight(.bold)).tracking(1)
                Button {
                    lobby.invite(pilotID: opponentID, name: opponent, using: online)
                } label: {
                    Label(next.inviterID == localID ? "Invite \(opponent)" : "Invite anyway", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .accessibilityIdentifier("tournament-invite")
            }
        } else if tournament.status == .underway, tournament.isEntered(localID), tournament.bracket.champion == nil {
            Text(tournament.bracket.isEliminated(localID) ? "You are out of this one." : "Waiting on the other fixtures.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Rounds as columns, left to right, with the winner of each pairing lit.
private struct BracketView: View {
    let bracket: Bracket
    let names: [String: String]
    let localID: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(bracket.rounds.enumerated()), id: \.offset) { index, round in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(roundName(index, of: bracket.rounds.count))
                            .font(.caption2.monospaced().weight(.bold)).tracking(1.5)
                            .foregroundStyle(.secondary)
                        ForEach(round) { pairing in cell(pairing) }
                    }
                }
            }
        }
        .accessibilityIdentifier("tournament-bracket")
    }

    private func roundName(_ index: Int, of count: Int) -> String {
        switch count - index {
        case 1: "FINAL"
        case 2: "SEMIS"
        case 3: "QUARTERS"
        default: "ROUND \(index + 1)"
        }
    }

    private func cell(_ pairing: Bracket.Pairing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            line(pairing.homeID, score: pairing.score?.cyan, pairing: pairing)
            Divider().overlay(.white.opacity(0.15))
            line(pairing.awayID, score: pairing.score?.orange, pairing: pairing)
        }
        .frame(width: 168)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pairing.isReady ? .cyan.opacity(0.5) : .white.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    private func line(_ playerID: String?, score: Int?, pairing: Bracket.Pairing) -> some View {
        let name: String = if let playerID { names[playerID, default: "?"] } else { pairing.isBye ? "BYE" : "TBD" }
        let won = playerID != nil && pairing.winnerID == playerID
        let lost = playerID != nil && pairing.isDecided && !won
        return HStack {
            Text(name.uppercased())
                .font(.caption.monospaced().weight(won ? .black : .regular))
                .foregroundStyle(playerID == nil ? .secondary : won ? Color.cyan : lost ? Color.secondary : Color.primary)
                .lineLimit(1)
            Spacer()
            if let score { Text("\(score)").font(.caption.monospaced().bold()) }
            if won { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.cyan) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .overlay(alignment: .leading) {
            if playerID == localID { Rectangle().fill(.cyan).frame(width: 3) }
        }
    }
}
