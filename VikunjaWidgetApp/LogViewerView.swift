import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Read-only in-app viewer for the diagnostic log — reachable only from
/// `BugReportSheet`, so a user can check the privacy claim before sending.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText: String = ""
    @State private var showCopiedBanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Diagnostic Log")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        copyToClipboard()
                        withAnimation { showCopiedBanner = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { showCopiedBanner = false }
                        }
                    } label: {
                        Label(showCopiedBanner ? "Copied" : "Copy All",
                              systemImage: showCopiedBanner ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .task {
                // Reading and line-splitting up to ~768 KB off the main
                // thread. `.task` alone isn't enough — its closure inherits
                // the view's MainActor isolation, so the work has to be
                // handed to a detached task explicitly.
                logText = await Task.detached(priority: .utility) {
                    DiagnosticLog.viewerText()
                }.value
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
        #else
        UIPasteboard.general.string = logText
        #endif
    }
}
