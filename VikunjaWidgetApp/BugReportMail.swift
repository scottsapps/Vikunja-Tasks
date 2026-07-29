import Foundation
#if os(iOS)
import MessageUI
import UIKit
#endif
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// One SwiftUI-facing entry point (`present(attachLog:onFinish:)`) hiding the
/// iOS/macOS mail split — `MessageUI` doesn't exist on macOS, so the two
/// platforms need entirely different presentation paths. `BugReportSheet`
/// just calls this; it has no platform conditionals of its own beyond sizing.
enum BugReportMail {
    static let supportAddress = "scottsapps@protonmail.com"

    static func present(attachLog: Bool, onFinish: @escaping () -> Void) {
        DiagnosticLog.breadcrumb("mailCompose")
        #if os(iOS)
        presentIOS(attachLog: attachLog, onFinish: onFinish)
        #elseif os(macOS)
        presentMacOS(attachLog: attachLog, onFinish: onFinish)
        #endif
    }

    // MARK: - Shared content

    private static func subject() -> String { "Veyrn Bug Report" }

    private static func bodyText() -> String {
        let (version, build) = DiagnosticLog.appVersionAndBuild()
        return """
        What went wrong?


        What were you doing when it happened?


        ---
        Veyrn \(version) (\(build))
        \(DiagnosticLog.osNameVersionBuild())
        """
    }

    private static func attachmentFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        df.locale = Locale(identifier: "en_US_POSIX")
        return "veyrn-log-\(df.string(from: Date())).txt"
    }
}

// MARK: - iOS

#if os(iOS)
extension BugReportMail {
    fileprivate static var activeCoordinators: [MailCoordinator] = []

    private static func presentIOS(attachLog: Bool, onFinish: @escaping () -> Void) {
        guard let root = topViewController() else { onFinish(); return }

        if MFMailComposeViewController.canSendMail() {
            let vc = MFMailComposeViewController()
            let coordinator = MailCoordinator(onFinish: onFinish)
            activeCoordinators.append(coordinator)
            vc.mailComposeDelegate = coordinator
            vc.setToRecipients([supportAddress])
            vc.setSubject(subject())
            vc.setMessageBody(bodyText(), isHTML: false)
            if attachLog {
                vc.addAttachmentData(DiagnosticLog.bundledLogData(), mimeType: "text/plain", fileName: attachmentFilename())
            }
            root.present(vc, animated: true)
        } else {
            presentShareSheetFallback(attachLog: attachLog, from: root, onFinish: onFinish)
        }
    }

    /// No Mail account configured — offer the share sheet (Gmail, Outlook,
    /// Spark, etc. can all take a file attachment) before falling all the way
    /// back to "copy and paste it yourself".
    private static func presentShareSheetFallback(attachLog: Bool, from root: UIViewController, onFinish: @escaping () -> Void) {
        var items: [Any] = [bodyText()]
        var tempURL: URL?
        if attachLog {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachmentFilename())
            if (try? DiagnosticLog.bundledLogData().write(to: url)) != nil {
                items.append(url)
                tempURL = url
            }
        }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            if completed {
                onFinish()
            } else {
                copyToClipboardAndAlert(attachLog: attachLog, from: root, onFinish: onFinish)
            }
        }
        root.present(activityVC, animated: true)
    }

    private static func copyToClipboardAndAlert(attachLog: Bool, from root: UIViewController, onFinish: @escaping () -> Void) {
        UIPasteboard.general.string = attachLog
            ? (String(data: DiagnosticLog.bundledLogData(), encoding: .utf8) ?? bodyText())
            : bodyText()
        let alert = UIAlertController(
            title: "Mail Not Available",
            message: "The report has been copied to your clipboard. Please paste it into an email to \(supportAddress).",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in onFinish() })
        root.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

private final class MailCoordinator: NSObject, MFMailComposeViewControllerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        controller.dismiss(animated: true) { self.onFinish() }
        BugReportMail.activeCoordinators.removeAll { $0 === self }
    }
}
#endif

// MARK: - macOS

#if os(macOS)
extension BugReportMail {
    private static func presentMacOS(attachLog: Bool, onFinish: @escaping () -> Void) {
        var tempURL: URL?
        if attachLog {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachmentFilename())
            if (try? DiagnosticLog.bundledLogData().write(to: url)) != nil {
                tempURL = url
            }
        }

        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [supportAddress]
            service.subject = subject()
            var items: [Any] = [bodyText()]
            if let tempURL { items.append(tempURL) }
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                onFinish()
                return
            }
        }

        // No mail client configured — offer to save the log for webmail
        // users, falling back to a clipboard copy either way.
        offerSaveOrClipboardFallback(attachLog: attachLog, tempURL: tempURL, onFinish: onFinish)
    }

    private static func offerSaveOrClipboardFallback(attachLog: Bool, tempURL: URL?, onFinish: @escaping () -> Void) {
        defer { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }

        let alert = NSAlert()
        alert.messageText = "No Mail App Configured"
        alert.informativeText = attachLog
            ? "Save the log to a file to attach to an email yourself, or copy the report text to send from webmail."
            : "Copy the report text and paste it into an email to \(supportAddress)."
        alert.addButton(withTitle: attachLog ? "Save Log to File…" : "Copy Report Text")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            onFinish()
            return
        }
        if attachLog {
            saveLogToFile(onFinish: onFinish)
        } else {
            copyToClipboardAndNotify(savedFile: false, onFinish: onFinish)
        }
    }

    private static func saveLogToFile(onFinish: @escaping () -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachmentFilename()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            onFinish()
            return
        }
        try? DiagnosticLog.bundledLogData().write(to: url)
        copyToClipboardAndNotify(savedFile: true, onFinish: onFinish)
    }

    private static func copyToClipboardAndNotify(savedFile: Bool, onFinish: @escaping () -> Void) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bodyText(), forType: .string)

        let alert = NSAlert()
        alert.messageText = savedFile ? "Log Saved" : "Copied to Clipboard"
        alert.informativeText = savedFile
            ? "Attach the saved file and send the email to \(supportAddress). The report text is also on your clipboard."
            : "Paste the report text into an email to \(supportAddress)."
        alert.addButton(withTitle: "OK")
        alert.runModal()

        let encodedSubject = subject().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let mailtoURL = URL(string: "mailto:\(supportAddress)?subject=\(encodedSubject)") {
            NSWorkspace.shared.open(mailtoURL)
        }
        onFinish()
    }
}
#endif
