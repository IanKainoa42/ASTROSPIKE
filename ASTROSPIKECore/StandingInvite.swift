import Foundation

// A Game Center invitation is a live handshake: it exists only while the
// pilot who sent it is sitting in matchmaking, and it dies the moment they
// put the phone down. That is fine for "duel me now" and useless for "duel
// me when you're next free", which is how two people with jobs actually
// arrange a game.
//
// A standing invite is the durable half of that. It is a stored intent --
// Ian asked Maya for a duel, and the ask keeps until Maya answers it or it
// ages out -- and it carries no connection of its own. When Maya finally
// opens the app and taps JOIN, *her* board sends the live Game Center
// invitation back to Ian, whose phone can have been in a pocket all day:
// GameKit delivers that one as a push, so nothing had to stay running.
//
// This file is the record shapes and the arithmetic over them. The app keeps
// them in CloudKit -- one `StandingInvite` written by the host, one
// `StandingInviteReply` written by the guest, never a record two pilots both
// write -- and this file never learns that.

/// Where a standing invite has got to. Derived, never stored: the store
/// holds the invite and (maybe) a reply, and the rest is the clock.
public enum StandingInviteStatus: Equatable, Sendable {
    /// Sent, unanswered, still inside its window.
    case open
    /// The guest said yes. Their board fires the live Game Center invite.
    case accepted
    /// The guest said no.
    case declined
    /// The host took it back before it was answered.
    case withdrawn
    /// Nobody answered inside the window.
    case expired

    /// True while the invite is still worth showing to either pilot.
    public var isLive: Bool { self == .open }

    public var label: String {
        switch self {
        case .open: "WAITING"
        case .accepted: "ACCEPTED"
        case .declined: "DECLINED"
        case .withdrawn: "WITHDRAWN"
        case .expired: "EXPIRED"
        }
    }
}

/// One pilot asking another for a duel, whenever they next get to it.
public struct StandingInvite: Codable, Equatable, Sendable, Identifiable {
    /// Stable per (host, guest) pair, so a second ask replaces the first
    /// rather than stacking a queue of identical rows on the guest's screen.
    public var id: String
    /// Game Center `gamePlayerID` of the pilot who asked.
    public var hostID: String
    public var hostName: String
    public var hostHull: Hull
    /// Game Center `gamePlayerID` of the pilot being asked.
    public var guestID: String
    public var guestName: String
    public var createdAt: Date
    public var expiresAt: Date
    /// Set by the host to take the ask back. The host owns this record, so
    /// this is the only field either side can flip without a shared write.
    public var withdrawn: Bool

    public init(
        id: String,
        hostID: String,
        hostName: String,
        hostHull: Hull,
        guestID: String,
        guestName: String,
        createdAt: Date,
        expiresAt: Date,
        withdrawn: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.hostHull = hostHull
        self.guestID = guestID
        self.guestName = guestName
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.withdrawn = withdrawn
    }

    /// The record name both ends compute without talking to each other, so
    /// re-inviting the same pilot overwrites rather than duplicates.
    public static func id(hostID: String, guestID: String) -> String {
        "\(hostID)|\(guestID)"
    }

    public func involves(_ playerID: String) -> Bool {
        hostID == playerID || guestID == playerID
    }

    /// The other pilot, from one end's point of view.
    public func opponentName(for playerID: String) -> String {
        playerID == hostID ? guestName : hostName
    }
}

/// The guest's answer. A separate record because the guest cannot write the
/// host's: every record in the lobby has exactly one author.
public struct StandingInviteReply: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var inviteID: String
    public var guestID: String
    public var accepted: Bool
    public var repliedAt: Date

    public init(inviteID: String, guestID: String, accepted: Bool, repliedAt: Date) {
        id = "\(inviteID)|reply"
        self.inviteID = inviteID
        self.guestID = guestID
        self.accepted = accepted
        self.repliedAt = repliedAt
    }
}

/// Every standing invite this pilot can see, and the questions the screens
/// ask of them. Rebuilt from the records on each read -- like the bracket,
/// nothing here is incrementally maintained state that could drift.
public struct StandingInviteBook: Equatable, Sendable {
    /// How long an unanswered ask keeps. Long enough to span a working day
    /// and a night's sleep; short enough that a forgotten invite does not
    /// ambush someone a week later.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public private(set) var invites: [StandingInvite]
    /// Replies by `inviteID`. At most one per invite; a later reply to the
    /// same invite overwrites the earlier, because the guest changed answer.
    public private(set) var replies: [String: StandingInviteReply]

    public init(invites: [StandingInvite] = [], replies: [StandingInviteReply] = []) {
        // A stale duplicate can survive a CloudKit window query when a pair
        // re-invite lands under a new record name; keep the newest per pair.
        var newest: [String: StandingInvite] = [:]
        for invite in invites {
            let key = StandingInvite.id(hostID: invite.hostID, guestID: invite.guestID)
            if let held = newest[key], held.createdAt >= invite.createdAt { continue }
            newest[key] = invite
        }
        self.invites = newest.values.sorted { $0.createdAt > $1.createdAt }
        var latest: [String: StandingInviteReply] = [:]
        for reply in replies {
            if let held = latest[reply.inviteID], held.repliedAt >= reply.repliedAt { continue }
            latest[reply.inviteID] = reply
        }
        self.replies = latest
    }

    public func expiry(from now: Date) -> Date { now.addingTimeInterval(Self.lifetime) }

    /// Withdrawal beats a reply that has not arrived; an answer beats the
    /// clock, so an invite accepted a minute before it aged out still reads
    /// as accepted rather than silently becoming expired.
    public func status(of invite: StandingInvite, at now: Date) -> StandingInviteStatus {
        // The record name is fixed per pair, so the reply to the last ask
        // is still sitting there when the host asks again. It answered that
        // ask, not this one.
        if let reply = replies[invite.id], reply.repliedAt >= invite.createdAt {
            return reply.accepted ? .accepted : .declined
        }
        if invite.withdrawn { return .withdrawn }
        if now >= invite.expiresAt { return .expired }
        return .open
    }

    /// Asks pointed at this pilot that still want an answer, newest first.
    public func inbox(for localID: String, at now: Date) -> [StandingInvite] {
        invites.filter { $0.guestID == localID && status(of: $0, at: now).isLive }
    }

    /// Asks this pilot sent that are still waiting, newest first. Answered
    /// ones drop off here too: the answer arrives as a live Game Center
    /// invite, which has its own screen.
    public func outbox(from localID: String, at now: Date) -> [StandingInvite] {
        invites.filter { $0.hostID == localID && status(of: $0, at: now).isLive }
    }

    /// True when a fresh ask to this pilot would only repeat one already
    /// waiting -- the invite button says WAITING rather than sending again.
    public func hasOpenInvite(from localID: String, to guestID: String, at now: Date) -> Bool {
        outbox(from: localID, at: now).contains { $0.guestID == guestID }
    }

    /// Answers this pilot's own asks have collected since they last looked,
    /// so the lobby can say "Maya declined" instead of going quiet. Only
    /// settled ones: an open invite has nothing to report.
    public func answers(for localID: String, at now: Date) -> [(invite: StandingInvite, status: StandingInviteStatus)] {
        invites
            .filter { $0.hostID == localID }
            .map { ($0, status(of: $0, at: now)) }
            .filter { $0.1 == .accepted || $0.1 == .declined }
    }
}

// MARK: - Meeting in game

/// How a duel ask reaches the other pilot.
///
/// A Game Center invitation always lands as Apple's banner, on both ends:
/// the guest taps it to accept, and a standing invite's JOIN sends one back
/// that the host has to tap in turn. When both pilots already have the app
/// open there is a way round that: each searches a private automatch pool
/// that only this invite knows the number of, and GameKit pairs them with no
/// sheet or banner on either phone. The invite's row in the app is the
/// whole of the handshake.
public enum InviteRoute: Equatable, Sendable {
    /// Both in the app. They meet in automatch pool `group`.
    case inGame(group: Int)
    /// The host is waiting on a Game Center invitation to this very guest.
    /// Sending one back would cross the two invites, and each phone cancels
    /// the other's. Instead the guest answers yes, the host sees it and
    /// moves to pool `group`, and they meet there.
    case callHostToPool(group: Int)
    /// A Game Center invitation, delivered as a push.
    case gameCenter
}

extension StandingInvite {
    /// The private automatch pool this ask meets in. Both phones compute it
    /// from the record alone, so it is a stable hash -- `hashValue` is seeded
    /// per process and would put them in different pools -- and it is never
    /// 0, the pool every quick match searches.
    public var rendezvousGroup: Int {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(id)|\(Int(createdAt.timeIntervalSince1970.rounded(.down)))".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let group = Int(hash & 0x7FFF_FFFF)
        return group == 0 ? 1 : group
    }

    /// What the host's presence says while it waits in that pool, so the
    /// guest knows to meet it there rather than ring its phone.
    public var rendezvousTag: String { "rv:\(id)" }

    /// What the host's presence says while it waits on the Game Center push
    /// it sent for this ask.
    public var pushTag: String { "gc:\(id)" }
}

public enum InviteRouting {
    /// A presence older than this is a phone that may be in a pocket. The
    /// heartbeat beats every 30 seconds while the app is open and stops when
    /// it is not, so anything fresher means the app was up a moment ago.
    public static let presenceWindow: TimeInterval = 45

    /// The host sending: meet in game when the guest is looking at the
    /// app's menus, and ring their phone otherwise -- a pilot in the bay,
    /// mid-game against a bot, or away, needs the push.
    public static func send(_ invite: StandingInvite, guest: PilotPresence?, at now: Date) -> InviteRoute {
        guard let guest, guest.id == invite.guestID,
              now.timeIntervalSince(guest.updatedAt) <= presenceWindow,
              // Only the menus show the in-game banner. A pilot in the
              // warm-up bay reads `.matching` but would never see the ask,
              // so they get Apple's push like anyone else who is busy.
              guest.activity == .idle else { return .gameCenter }
        return .inGame(group: invite.rendezvousGroup)
    }

    /// The guest answering: meet in game when the host is still waiting on
    /// this very ask -- in the pool already, or on the push it sent, which
    /// it leaves for the pool once it sees the yes. Otherwise the host has
    /// moved on, and JOIN sends the invitation back to them as a push.
    public static func join(_ invite: StandingInvite, host: PilotPresence?, at now: Date) -> InviteRoute {
        guard let host, host.id == invite.hostID,
              now.timeIntervalSince(host.updatedAt) <= presenceWindow,
              host.activity == .matching else { return .gameCenter }
        switch host.matchID {
        case invite.rendezvousTag: return .inGame(group: invite.rendezvousGroup)
        case invite.pushTag: return .callHostToPool(group: invite.rendezvousGroup)
        default: return .gameCenter
        }
    }

    /// The host waiting on a push for `invite`: once the guest has said yes
    /// in the app, stop waiting on the push and meet them in the pool.
    public static func hostMovesToPool(_ invite: StandingInvite, waitingOn tag: String?, status: StandingInviteStatus) -> Bool {
        tag == invite.pushTag && status == .accepted
    }
}
