import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Emotes")
struct EmoteTests {
    @Test("An emote survives the wire")
    func emoteRoundTrip() throws {
        let codec = WireCodec()
        for emote in Emote.allCases {
            let envelope = WireEnvelope(sequence: 7, payload: .emote(emote))
            #expect(try codec.decode(codec.encode(envelope)) == envelope)
        }
    }

    /// The drawn hull is the hitbox, and the pilot is still flying through
    /// the emote: it must never draw the ship bigger than it is.
    @Test("No emote ever draws the hull bigger than it is")
    func hullNeverGrows() {
        for emote in Emote.allCases {
            for step in 0...400 {
                let pose = emote.pose(at: Double(step) / 400)
                #expect(abs(pose.scaleX) <= 1, "\(emote) scaleX \(pose.scaleX) at \(step)")
                #expect(pose.scaleY <= 1 && pose.scaleY > 0.5, "\(emote) scaleY \(pose.scaleY) at \(step)")
            }
        }
    }

    /// Ian's rule: no emoji anywhere. The picker draws SF Symbols, whose
    /// names are plain ASCII.
    @Test("Emote icons are SF Symbol names, never emoji")
    func symbolsAreNotEmoji() {
        for emote in Emote.allCases {
            #expect(!emote.symbol.isEmpty && emote.symbol.unicodeScalars.allSatisfy(\.isASCII), "\(emote)")
        }
    }

    @Test("Every emote ends with the hull at rest")
    func endsAtRest() {
        for emote in Emote.allCases {
            #expect(emote.pose(at: 1) == .rest)
            #expect(emote.pose(at: 0) == .rest)
            #expect(emote.pose(at: 3) == .rest)
            #expect(emote.bursts.allSatisfy { (0..<1).contains($0) })
        }
    }

    @Test("Every emote visibly does something")
    func emotesMove() {
        for emote in Emote.allCases {
            let moved = (1..<100).contains { step in
                emote.pose(at: Double(step) / 100) != .rest
            }
            #expect(moved, "\(emote) never leaves its rest pose")
        }
    }

    @Test("The cooldown refuses a second emote inside its window")
    func cooldown() {
        var cooldown = EmoteCooldown()
        let first = cooldown.attempt(at: 10)
        let tooSoon = cooldown.attempt(at: 11)
        let remaining = cooldown.remaining(at: 11.5)
        let stillTooSoon = cooldown.attempt(at: 12.9)
        let ready = cooldown.attempt(at: 13)
        #expect(first && !tooSoon && !stillTooSoon && ready)
        #expect(remaining == 1.5)
        #expect(cooldown.remaining(at: 13) == 3)
    }
}
