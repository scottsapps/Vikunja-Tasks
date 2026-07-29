import SwiftUI

/// Confirmation sheet shown before a bug report leaves the device. Logging
/// is always on and local-only — nothing is transmitted until the user taps
/// one of the two Send buttons here, and View Log exists so the privacy
/// claim below is checkable, not just asserted.
struct BugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showLogViewer = false

    // Loaded once, off the main thread. As a computed property this re-read
    // every log file from disk on every SwiftUI body pass.
    @State private var logSizeDescription = " "

    var body: some View {
        NavigationStack {
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
                        BugReportMail.present(attachLog: false) { dismiss() }
                    } label: {
                        Label("Send Without Log", systemImage: "envelope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        BugReportMail.present(attachLog: true) { dismiss() }
                    } label: {
                        Label("Send With Log", systemImage: "paperclip")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                Spacer()

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
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}
