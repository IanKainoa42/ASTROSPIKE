import ASTROSPIKECore
import SwiftUI

struct AstroSPIKESettingsView: View {
    @Bindable var tuning: FlightTuningStore
    var replayIntro: (() -> Void)?
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("clusterControls") private var clusterControls = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage(Soundscape.enabledKey) private var music = true
    @AppStorage(GameSession.muteEmotesKey) private var muteEmotes = false
    @State private var arrangingControls = false
    @AppStorage(PadLayout.key) private var padLayout = PadLayout.diamond
    @AppStorage(SteeringCurve.sensitivityKey) private var steeringSensitivity = 1.0
    @AppStorage(ShipHitbox.perHullKey) private var hullShapedHitboxes = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TuningSlider(
                        title: "Turning sensitivity",
                        value: $steeringSensitivity,
                        range: SteeringCurve.sensitivityRange,
                        step: 0.05,
                        readout: { "\(Int(($0 * 100).rounded()))%" }
                    )
                    .accessibilityIdentifier("turning-sensitivity")
                    Toggle("Swap controls for left-handed play", isOn: $leftHanded)
                        .accessibilityIdentifier("left-handed")
                    Stepper(
                        "Bounces per hit: \(tuning.allowedBouncesPerHit)",
                        value: $tuning.allowedBouncesPerHit,
                        in: 1 ... 5
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("bounces-per-hit")
                    Button("Reset to default") { steeringSensitivity = 1 }
                        .disabled(steeringSensitivity == 1)
                    Toggle("Large controls", isOn: $largeControls)
                        .accessibilityIdentifier("large-controls")
                    Toggle("Cluster controls to thumb side", isOn: $clusterControls)
                        .accessibilityIdentifier("cluster-controls")
                    Picker("Engine pads", selection: $padLayout) {
                        Text("Diamond").tag(PadLayout.diamond)
                        Text("Classic").tag(PadLayout.classic)
                    }
                    .accessibilityIdentifier("pad-layout")
                    Button {
                        arrangingControls = true
                    } label: {
                        Label("Arrange Touch Controls", systemImage: "hand.draw.fill")
                    }
                    .accessibilityIdentifier("arrange-controls")
                    Button("Reset pad layout") {
                        UserDefaults.standard.removeObject(forKey: "padOffsets2")
                        UserDefaults.standard.removeObject(forKey: "padOffsetsDiamond")
                    }
                } header: {
                    Text("Steering")
                } footer: {
                    Text("Higher turns harder the moment you press the steering pad and needs less slide to reach a full turn. Top turning speed is the same at every setting.")
                }
                Section("Match Rules") {
                    Picker("Match length", selection: $tuning.setsToWin) {
                        Text("Single game").tag(1)
                        Text("Best of 3").tag(2)
                        Text("Best of 5").tag(3)
                    }
                    .accessibilityIdentifier("match-length")
                    Picker("Arena", selection: $tuning.arenaLayout) {
                        ForEach(ArenaLayout.allCases, id: \.self) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .accessibilityIdentifier("arena-layout")
                    if tuning.arenaLayout == .bumpers {
                        TuningSlider(
                            title: "Peg pull",
                            value: $tuning.pegPull,
                            range: FlightTuningSnapshot.pegPullRange,
                            step: 0.05,
                            readout: { $0.formatted(.number.precision(.fractionLength(2))) + "x" }
                        )
                        .accessibilityIdentifier("peg-pull")
                    }
                    Picker("Bolt hit", selection: $tuning.boltHit) {
                        ForEach(BoltHit.allCases, id: \.self) { hit in
                            Text(hit.title).tag(hit)
                        }
                    }
                    .accessibilityIdentifier("bolt-hit")
                    TuningSlider(
                        title: "Beam lock",
                        value: $tuning.beamLock,
                        range: FlightTuningSnapshot.beamLockRange,
                        step: 0.05,
                        readout: { $0.formatted(.number.precision(.fractionLength(2))) + " s" }
                    )
                    .accessibilityIdentifier("beam-lock")
                    TuningSlider(
                        title: "Beam swing",
                        value: $tuning.beamSwing,
                        range: FlightTuningSnapshot.beamSwingRange,
                        step: 0.05,
                        readout: { $0.formatted(.number.precision(.fractionLength(2))) + "x" }
                    )
                    .accessibilityIdentifier("beam-swing")
                    Text("Touches are unlimited. Bounces apply to solo matches; online uses three. Match length, arena, peg pull, bolt hit, beam lock and beam swing apply to solo and doubles matches and to any online match you host. Bolt hit is what an enemy bolt does to a hull: shove it, stun its controls for a moment, or spin it round. Beam lock is how long the beam holds the ball before it locks on: you and the ball then turn as one body until you let go. Let go sooner and it flies on in. The lock breaks if your hull touches the ground, if the ball touches the ground, a goal or a ledge, if another hull touches the ball, or if any bolt hits you or the ball, and no goal takes a locked ball: let go and throw it. A goal within a second of your beam letting go is your slam dunk, unless another pilot played the ball in between. The catch keeps the ball's run as swing; beam swing is how hard the stick pumps it while locked. Let go at speed to whip the ball off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Haptics", isOn: $haptics)
                    Toggle("Music", isOn: $music)
                    Toggle("Hide other pilots' emotes", isOn: $muteEmotes)
                        .onChange(of: music) { _, on in Soundscape.shared.enabled = on }
                    LabeledContent("Reduced Motion", value: "Follows iOS Accessibility")
                } header: {
                    Text("Sound & feel")
                }
                Section {
                    RingTuningControls(thrust: tuning.configuration.maximumThrustAcceleration)
                } header: {
                    Text("ASTROPUCK")
                } footer: {
                    Text(RingTuningControls.footer)
                }
                Section {
                    AstroballTuningControls()
                } header: {
                    Text("ASTROBALL")
                } footer: {
                    Text(AstroballTuningControls.footer)
                }
                if let replayIntro {
                    Section("Intro") {
                        Button("Replay intro", action: replayIntro)
                            .accessibilityIdentifier("replay-intro")
                    }
                }
                Section("Team symbols") { Label("Cyan uses a bar", systemImage: "minus"); Label("Orange uses a diamond", systemImage: "diamond.fill") }
                Section {
                    Toggle("Hull-shaped hitboxes", isOn: $hullShapedHitboxes)
                        .accessibilityIdentifier("hull-shaped-hitboxes")
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Off: every hull hits the ball with the Lancet's shape. On: each hull hits with its own outline. Takes effect next match; online matches always use the shared shape.")
                }
            }
            .accessibilityIdentifier("settings-form")
            .navigationTitle("Settings")
        }
        .fullScreenCover(isPresented: $arrangingControls) {
            ControlLayoutEditor()
        }
        .accessibilityIdentifier("settings-screen")
    }
}

/// The match's pads over an empty court, ready to drag: the very
/// `TouchControls` a match draws, in the same frame, with arranging on.
/// Its banner's DONE puts them back to work and closes this.
struct ControlLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("arrangePads") private var arranging = false
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @State private var torque = 0.0
    @State private var thrust = false
    @State private var fire = false
    @State private var tractor = false

    /// Stands in for the match HUD over the pads, so they land where a
    /// match puts them.
    private static let hudHeight: CGFloat = 54

    var body: some View {
        GeometryReader { geometry in
            let window = TouchControls.windowFrame(in: geometry)
            let centred = ArenaScene.arenaRect(in: window.size)
            let arena = centred.offsetBy(dx: window.midX, dy: window.midY)
            ZStack(alignment: .topLeading) {
                // The court: the pads should leave it clear.
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.35), lineWidth: 2)
                    .frame(width: arena.width, height: arena.height)
                    .position(
                        x: arena.midX - geometry.frame(in: .global).minX,
                        y: arena.midY - geometry.frame(in: .global).minY
                    )
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.hudHeight)
                    TouchControls(
                        torque: $torque,
                        thrust: $thrust,
                        fire: $fire,
                        tractor: $tractor,
                        largeControls: largeControls,
                        leftHanded: leftHanded,
                        arenaFrame: arena,
                        windowFrame: window,
                        saberChanged: { _ in },
                        saberFlicked: { _ in }
                    )
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { arranging = true }
        .onChange(of: arranging) { _, on in
            if !on { dismiss() }
        }
        .onDisappear { arranging = false }
        .accessibilityIdentifier("control-layout-editor")
    }
}

/// ASTROBALL's knobs, written straight to the pilot's defaults. A host's
/// settings ride the seating plan, so they fly on every phone.
struct AstroballTuningControls: View {
    @State private var tuning = AstroballTuning.stored()

    static let footer = "Solo touches is how many times a side flown by one pilot may play the ball before it has to be over: one touch and over, up to three. A side of two always gets three. In a row is how many times one pilot may play it running: two by default, so a double is fine and a triple gives the point away. Hull and bolts both count. Net touch is what flying into the top half of the net costs: Off, Stun (a second with dead controls, the default) or Point (your side loses it). There are two zones, each a stretch of each half's wall path (by default the floor nearest the net out to 28%, and a small target 7% to 13% up the side wall), from the foot of the net (0) along the floor, round the corner and up the side wall to the roof (1): the ball touching your zone gives the other side the point. Wall bounce is how much speed the ball keeps off the walls, roof and corners; lower soaks a spike up. Floor bounce is the same for the floor, and is never livelier than the walls, so a ball that lands stays down; the floor corners blend from one to the other. The MAX CROSS line rises from the top of the net and leans over the far half by the lean; fly past it and it slings you back. Takes effect next match, and online when you host."

    private var court: ArenaGeometry { .astroball(doubles: false) }

    var body: some View {
        Picker("Solo touches", selection: $tuning.soloTouches) {
            ForEach(Array(AstroballTuning.soloTouchesRange), id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AstroballTuning.soloTouchesKey)
        Picker("In a row", selection: $tuning.inARow) {
            ForEach(Array(AstroballTuning.inARowRange), id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AstroballTuning.inARowKey)
        Picker("Net touch", selection: $tuning.netTouch) {
            ForEach(NetTouch.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AstroballTuning.netTouchKey)
        TuningSlider(title: "Zone from", value: $tuning.zoneStart, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zoneStartKey)
        TuningSlider(title: "Zone to", value: $tuning.zoneEnd, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zoneEndKey)
        TuningSlider(title: "Zone 2 from", value: $tuning.zone2Start, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zone2StartKey)
        TuningSlider(title: "Zone 2 to", value: $tuning.zone2End, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zone2EndKey)
        TuningSlider(title: "Wall bounce", value: $tuning.wallBounce, range: AstroballTuning.wallBounceRange, step: 0.01,
                     readout: { "\(Int(($0 * 100).rounded()))%" })
            .accessibilityIdentifier(AstroballTuning.wallBounceKey)
        TuningSlider(title: "Floor bounce", value: $tuning.floorBounce, range: AstroballTuning.floorBounceRange, step: 0.01,
                     readout: { "\(Int((min($0, tuning.clampedWallBounce) * 100).rounded()))%" })
            .accessibilityIdentifier(AstroballTuning.floorBounceKey)
        TuningSlider(title: "MAX CROSS lean", value: $tuning.crossLean, range: AstroballTuning.crossLeanRange, step: 0.01)
            .accessibilityIdentifier(AstroballTuning.crossLeanKey)
        Button("Reset ASTROBALL to default") { tuning = AstroballTuning() }
            .disabled(tuning == AstroballTuning())
            .onChange(of: tuning) { _, tuning in tuning.store() }
    }
}

/// The circuit's own sliders, in `RaceTuningView`. The court's flight
/// sliders are gone: the ship and ball are baked, and only the match rules
/// in Settings are a pilot's to change.
struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// How the number beside the title reads. Two decimals suit the flight
    /// sliders, whose range is wide; the corridor moves in thousandths and
    /// is felt in hulls, so it gets to say so rather than showing the same
    /// rounded number at both ends of its travel.
    var readout: (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(2)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(readout(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(readout(value))
        }
    }
}

/// Every free-for-all knob, one slider each, written straight to the
/// pilot's defaults. `changed` hears every move, so the pause card can put
/// it into the match under the pilot's thumb.
struct RingTuningControls: View {
    /// The Thrust slider's top push, for the speed readout.
    let thrust: Double
    var changed: (RingTuning) -> Void = { _ in }
    @State private var tuning = RingTuning.stored()

    static let footer = "Thrust and hull drag set how the ring flies: speed builds toward thrust / drag, and lower drag glides further. MAX CROSS push and brake are how hard a rival's line shoves you back and how much speed it steals; the line is how far out each rival's arc stands. Goal pull is a separate loose spring on your hull only, back toward your own goal, harder the farther you fly; zero leaves it off and the puck is never pulled. Bump height is how far each goal's bump rises off the rim, as a share of the ring's radius (0 puts the goals flush in a plain round rim); bump width is how broad its bell is. Fire rate is the seconds between your bolts on the ring, apart from the duel's. The centre bumper stands in the middle when it is on, and the face-off drops just clear of it. Goal guards stand a round bumper in front of every goal; sliding, it rides a track across the mouth and stays wherever a hull, the beam or a bolt shoves it, and starts each point where Guard across puts it; stood still, Guard distance and Guard across are where it stays. Two balls puts a second one in play; a goal re-drops only the one that went in. Gravity tilts the table out to the rim. All of it applies the moment you resume."

    var body: some View {
        Group {
            Toggle("Centre bumper", isOn: Binding(
                get: { tuning.centreBumper },
                set: { tuning.centreBumper = $0 }
            ))
            .accessibilityLabel("Centre bumper")
            .accessibilityIdentifier(RingTuning.centreBumperKey)
            Toggle("Two balls", isOn: Binding(
                get: { tuning.twoBalls },
                set: { tuning.twoBalls = $0 }
            ))
            .accessibilityIdentifier(RingTuning.twoBallsKey)
            Toggle("Goal guards", isOn: Binding(
                get: { tuning.goalGuards },
                set: { tuning.goalGuards = $0 }
            ))
            .accessibilityIdentifier(RingTuning.goalGuardsKey)
            if tuning.goalGuards {
                Toggle("Guards slide", isOn: Binding(
                    get: { tuning.guardsSlide },
                    set: { tuning.guardsSlide = $0 }
                ))
                .accessibilityIdentifier(RingTuning.guardsSlideKey)
            }
            Button("Reset ring to default") { tuning = RingTuning() }
                .disabled(tuning == RingTuning())
                .accessibilityIdentifier("reset-ring-default")
            ForEach(RingTuning.knobs.filter { !RingTuning.guardKnobKeys.contains($0.key) }) { knob in
                slider(knob)
                if knob.keyPath == \RingTuning.hullDrag {
                    let top = thrust * tuning.speed / max(0.01, tuning.hullDrag)
                    let half = log(2) / max(0.01, tuning.hullDrag)
                    Text("Top speed \(top.formatted(.number.precision(.fractionLength(2)))), half of it in \(half.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if tuning.goalGuards {
                ForEach(RingTuning.knobs.filter { RingTuning.guardKnobKeys.contains($0.key) }) { knob in
                    slider(knob)
                }
            }
        }
        .onChange(of: tuning) { _, tuning in
            tuning.store()
            changed(tuning)
        }
    }

    private func slider(_ knob: RingTuning.Knob) -> some View {
        TuningSlider(
            title: knob.title,
            value: Binding(
                get: { tuning[keyPath: knob.keyPath] },
                set: { tuning[keyPath: knob.keyPath] = $0 }
            ),
            range: knob.range,
            step: knob.step,
            readout: { knob.percent ? "\(Int(($0 * 100).rounded()))%" : knob.degrees ? "\(Int($0.rounded()))°" : knob.seconds ? "\($0.formatted(.number.precision(.fractionLength(2)))) s" : $0.formatted(.number.precision(.fractionLength(2))) }
        )
        .accessibilityIdentifier(knob.key)
    }
}
