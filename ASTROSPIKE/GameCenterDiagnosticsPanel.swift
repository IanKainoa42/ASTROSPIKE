import ASTROSPIKECore
import SwiftUI

struct GameCenterDiagnosticsPanel: View {
    let diagnostics: OnlineDiagnosticsSnapshot

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(linkColor)
                    Text("GC DIAGNOSTICS")
                        .font(.caption2.monospaced().weight(.black))
                        .tracking(1.1)
                    Circle()
                        .fill(linkColor)
                        .frame(width: 6, height: 6)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse Game Center diagnostics" : "Expand Game Center diagnostics")
            .accessibilityIdentifier("game-center-diagnostics-toggle")

            if isExpanded {
                HStack(spacing: 7) {
                    metric("PLAYER", diagnostics.playerLabel, width: 112, identifier: "diagnostics-player-value")
                    metric("SIDE", diagnostics.sideLabel, width: 55, identifier: "diagnostics-side-value")
                    metric("ROLE", diagnostics.authorityLabel, width: 55, identifier: "diagnostics-authority-value")
                    metric("PING", diagnostics.pingLabel, width: 54, identifier: "diagnostics-ping-value")
                    metric("LINK", diagnostics.linkLabel, width: 92, identifier: "diagnostics-link-value")
                    metric("MATCH", diagnostics.matchmakingLabel, width: 92, identifier: "diagnostics-match-value")
                    metric("RETRY", diagnostics.reconnectLabel, width: 54, identifier: "diagnostics-reconnect-value")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(linkColor.opacity(0.65), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game-center-diagnostics-panel")
    }

    private func metric(_ title: String, _ value: String, width: CGFloat, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityIdentifier(identifier)
        }
        .frame(width: width, alignment: .leading)
    }

    private var linkColor: Color {
        switch diagnostics.linkState {
        case .connected, .ready: .green
        case .reconnecting, .matchmaking, .authenticating: .yellow
        case .failed: .orange
        case .signedOut: .white.opacity(0.5)
        }
    }
}
