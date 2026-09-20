import SwiftUI
import UIKit

/// The whole Game Center transcript, readable and sendable.
///
/// The diagnostics panel in the HUD shows five lines because that is all
/// that fits over a live court. This is the same log with nothing trimmed,
/// plus the share sheet: multiplayer is only ever debugged from what the
/// pilot can send back after the fact.
struct LinkLogView: View {
    let transcript: String
    let events: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if events.isEmpty {
                            Text("NOTHING YET. SIGN IN TO GAME CENTER AND INVITE SOMEBODY.")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                            Text(event)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(index == events.count - 1 ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .onAppear {
                    // The newest line is the one that matters; a log that
                    // opens at the top makes the pilot scroll to find it.
                    guard !events.isEmpty else { return }
                    proxy.scrollTo(events.count - 1, anchor: .bottom)
                }
            }
            .navigationTitle("Link Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("link-log-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(events.isEmpty)
                    .accessibilityIdentifier("link-log-share")
                }
            }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: [transcript])
            }
        }
    }
}

/// `ShareLink` cannot hand a plain string to Mail as an attachment, and the
/// transcript wants to arrive as something readable rather than a wall of
/// pasted text, so this stays on the UIKit sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
