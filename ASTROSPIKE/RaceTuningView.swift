import ASTROSPIKECore
import SwiftUI

/// The circuit's dev sliders. Everything here is peculiar to racing -- how
/// wide the corridor is, what a scrape costs, how hard the pace ship tries.
/// The flight model is deliberately absent: the race flies the match's ship
/// under the match's gravity, off the match's sliders, and that is the point
/// of it. Changing anything here drops the field back onto a fresh grid,
/// because the corridor's width decides where the grid and the railing are.
struct RaceTuningView: View {
    @Bindable var tuning: TrackTuningStore
    /// Present while a race is actually running, so a change can be taken.
    var restart: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox("Corridor") {
                    VStack(spacing: 14) {
                        TuningSlider(
                            title: "Lane width",
                            value: $tuning.laneHalfWidth,
                            range: TrackGeometry.halfWidthLimits.minimum
                                ... TrackGeometry.halfWidthLimits.maximum,
                            step: 0.001,
                            // The whole corridor, counted in hulls. This
                            // circuit only has a thousandth or two to give
                            // either way, so "0.10" at both ends of the
                            // travel would read as a slider that does
                            // nothing -- and it is not nothing: it is the
                            // difference between two hulls of road and two
                            // and a third.
                            readout: {
                                let hull = 2 * TrackConfiguration().shipRadius
                                return ($0 * 2 / hull)
                                    .formatted(.number.precision(.fractionLength(2)))
                                    + " hulls"
                            }
                        )
                        Stepper(
                            tuning.laps <= 0 ? "Laps: endless loop" : "Laps: \(tuning.laps)",
                            value: $tuning.laps,
                            in: 0 ... 20
                        )
                        .accessibilityIdentifier("laps-stepper")
                    }
                }
                GroupBox("Hitting the Rail") {
                    VStack(spacing: 14) {
                        TuningSlider(
                            title: "Damage seconds",
                            value: $tuning.damageSeconds,
                            range: 0 ... 10,
                            step: 0.5
                        )
                        TuningSlider(
                            title: "Power while damaged",
                            value: $tuning.damagePowerKept,
                            range: 0.05 ... 1,
                            step: 0.05
                        )
                        TuningSlider(
                            title: "Speed kept on contact",
                            value: $tuning.railSpeedKept,
                            range: 0.1 ... 1,
                            step: 0.05
                        )
                    }
                }
                GroupBox("Pace Ship") {
                    TuningSlider(
                        title: "Rival pace",
                        value: $tuning.rivalPace,
                        range: 0.4 ... 1.2,
                        step: 0.02
                    )
                }
                Text("""
                A rail scrape never takes the controls away: the ship keeps \
                steering at full authority and only loses engine power, for \
                the seconds set above. A lap runs about six seconds, so \
                anything past three is already most of a lap.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let restart {
                    Button("Apply and Restart Race", action: restart)
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .accessibilityIdentifier("apply-race-tuning")
                }
                Button("Reset Defaults", role: .destructive) { tuning.reset() }
                    .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .navigationTitle("Race Tuning")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("race-tuning-screen")
    }
}
