import SwiftUI

/// The actual report-a-bug actions: explanation, log size, and the three
/// buttons. Shared by `BugReportSheet` (iOS's and onboarding's modal) and the
/// macOS Settings "Help" tab, which shows this directly — no launcher button
/// in between — since a tab is already one click from Settings' root.
///
/// Logging is always on and local-only — nothing is transmitted until the
/// user taps one of the two Send buttons, and View Log exists so the privacy
/// claim below is checkable, not just asserted.
struct BugReportBody: View {
    var onSent: () -> Void = {}

    @State private var showLogViewer = false

    // Loaded once, off the main thread. As a computed property this re-read
    // every log file from disk on every SwiftUI body pass.
    @State private var logSizeDescription = " "

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "ladybug")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Attach diagnostic log?")
                    .font(.title2.bold())
                Text("""
                The log records what Veyrn did — app launches, sync \
                results, errors. It never includes your server address, \
                your API token, or anything about your tasks: no \
                titles, projects, labels, or dates.
                \(logSizeDescription)
                """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 24)

            Divider()

            VStack(spacing: 12) {
                Button {
                    showLogViewer = true
                } label: {
                    Label("View Log", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    BugReportMail.present(attachLog: false) { onSent() }
                } label: {
                    Label("Send Without Log", systemImage: "envelope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    BugReportMail.present(attachLog: true) { onSent() }
                } label: {
                    Label("Send With Log", systemImage: "paperclip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showLogViewer) {
            LogViewerView()
        }
        .task {
            let bytes = await Task.detached(priority: .utility) {
                DiagnosticLog.bundledByteCount()
            }.value
            logSizeDescription = bytes == 0
                ? "Log is empty."
                : "Size: \(max(1, bytes / 1024)) KB"
        }
    }
}

/// The iOS (and onboarding) entry point: `BugReportBody` wrapped in navigation
/// chrome with a Cancel action, presented as a sheet. macOS's Settings "Help"
/// tab shows `BugReportBody` directly instead — see that type's doc comment.
struct BugReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BugReportBody(onSent: { dismiss() })
                Spacer(minLength: 0)

                #if os(macOS)
                // macOS has no swipe-to-dismiss, and .cancellationAction
                // placement in a bare sheet's toolbar is easy to miss — give
                // it a visible footer button here instead.
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
                #endif
            }
            .navigationTitle("Report a Bug")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}
