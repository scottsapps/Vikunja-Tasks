//
//  CalendarLauncher.swift
//  Veyrn (macOS)
//
//  Putting Apple Calendar on the day the user tapped in the calendar widget.
//
//  There is no URL route for this on macOS. Calendar.app registers only `webcal:`
//  and `ical:`, both of which *subscribe* to a remote calendar; the `calshow:<stamp>`
//  scheme the iOS widget uses is unclaimed here, so handing it to LaunchServices
//  raises the "There is no application set to open the URL" panel and opens nothing
//  (build 104 and earlier did exactly that). The only supported way in is Calendar's
//  scripting `view calendar at <date>` command.
//
//  That costs a one-time consent panel ("Veyrn wants to control Calendar") and needs
//  three build-side pieces, all of which must stay in place:
//
//  - `com.apple.security.automation.apple-events` — the hardened runtime's half.
//  - `com.apple.security.scripting-targets` (`com.apple.iCal` → `com.apple.iCal.UI`)
//    — the App Sandbox's half, and a *separate* check: with only the entitlement
//    above, the kernel drops the event (`deny(1) appleevent-send com.apple.ical`)
//    before TCC is ever consulted, so no consent panel appears and the send fails
//    with `-600 procNotFound` even though Calendar is plainly running. Build 105 and
//    106 both shipped that. `com.apple.iCal.UI` is the access group Calendar's own
//    sdef puts `view calendar` in — it grants navigation, not event data.
//  - `NSAppleEventsUsageDescription` in `Info.plist` — a *missing* usage string is a
//    hard crash when the event is sent, not a denial.
//
//  Calendar is always launched first and navigated second, so refusing consent (or
//  any later failure) still lands the user in Calendar — just on whatever day it was
//  already showing. See skill/references/calendar.md.
//

#if os(macOS)
import AppKit

enum CalendarLauncher {

    /// Brings Apple Calendar forward and, if it's allowed to, moves it to `day`.
    static func open(day: Date) {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: calendarBundleID
        ) else {
            DiagnosticLog.warn("calendar deep link: Calendar.app not found")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                DiagnosticLog.warn("calendar deep link: launch failed — \(VeyrnError.logDescription(for: error))")
                return
            }
            navigate(to: day)
        }
    }

    // MARK: - Private

    private static let calendarBundleID = "com.apple.iCal"

    // Calendar's `view calendar at <date>` command, straight out of its sdef:
    // `code="wrbtaec9"` is the event class + id, and its `at` parameter is `wtdt`.
    private static let viewCalendarClass = AEEventClass(0x7772_6274)  // 'wrbt'
    private static let viewCalendarID = AEEventID(0x6165_6339)        // 'aec9'
    private static let dateParameter = AEKeyword(0x7774_6474)         // 'wtdt'

    /// Sends the command as a raw Apple event rather than running an AppleScript.
    /// Scripting additions (`current date`) aren't dependable inside the sandbox, and
    /// AppleScript's alternative — a `date "…"` literal — is parsed in the user's
    /// locale; an `NSDate` descriptor sidesteps both.
    ///
    /// Runs off the main thread on purpose: the send blocks until Calendar answers,
    /// and on the first tap that means blocking until the consent panel is dismissed.
    /// On the main thread that reads as a beachball.
    private static func navigate(to day: Date, retriesLeft: Int = 1) {
        DispatchQueue.global(qos: .userInitiated).async {
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: viewCalendarClass,
                eventID: viewCalendarID,
                targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: calendarBundleID),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setDescriptor(
                NSAppleEventDescriptor(date: Calendar.current.startOfDay(for: day)),
                forKeyword: dateParameter
            )

            do {
                // `.canInteract` so the consent panel is allowed to appear, and a long
                // timeout because the reply waits on the user answering it.
                _ = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 120)
            } catch {
                let code = (error as NSError).code
                // -600 (procNotFound) immediately after launch just means Calendar
                // hasn't finished coming up; `openApplication`'s completion fires a
                // beat early.
                if code == -600, retriesLeft > 0 {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.75) {
                        navigate(to: day, retriesLeft: retriesLeft - 1)
                    }
                    return
                }
                // Expected whenever consent is declined (-1743). Calendar is open
                // either way, so there's nothing left to retry.
                DiagnosticLog.warn("calendar deep link: view-day event failed (\(code))")
            }
        }
    }
}
#endif
