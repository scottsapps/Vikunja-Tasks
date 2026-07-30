import Foundation

/// Detects a hung main thread — a beachball is not a crash, so nothing else
/// catches it. A 1 s timer on a utility queue pings the main queue; if the
/// ping hasn't been acknowledged after 3 s, the main thread is stuck.
///
/// Deliberately does not attempt to capture the main thread's stack (that
/// needs `task_threads`/`thread_get_state` unwinding and isn't worth it) —
/// `DiagnosticLog.breadcrumb(_:)`, set at the last few UI entry points before
/// the editor's hang cases, is the mechanism for naming the culprit.
enum HangWatchdog {
    private static let checkInterval: TimeInterval = 1
    private static let hangThreshold: TimeInterval = 3
    /// A gap this large between our own ticks means the process was frozen,
    /// not that the main thread is busy — the timer runs on its own queue and
    /// keeps firing through any amount of main-thread work.
    private static let suspensionTickGap: TimeInterval = 3
    private static var lastTickAt: Date?

    private static let stateLock = NSLock()
    private static var lastHeartbeat = Date()
    private static var isHanging = false
    private static var hangStart: Date?
    private static var isPaused = false
    private static var timer: DispatchSourceTimer?

    /// Stand down while the app isn't foreground-active. **Required on iOS**:
    /// a suspended process isn't a hung one, but from the watchdog's side the
    /// two look identical — it just sees a gap since the last heartbeat. The
    /// first real iOS log reported `main thread unresponsive ≥427.7 s` for an
    /// app that had simply been in the user's pocket for seven minutes. Left
    /// unfixed, every iOS bug report fills with false ERROR lines and a real
    /// beachball gets lost among them.
    static func pause() {
        stateLock.lock()
        isPaused = true
        isHanging = false
        hangStart = nil
        stateLock.unlock()
    }

    /// Resets the clock as well as clearing the flag — otherwise the gap
    /// accumulated while suspended is reported the moment we resume.
    static func resume() {
        let now = Date()
        stateLock.lock()
        let gap = now.timeIntervalSince(lastHeartbeat)
        isPaused = false
        isHanging = false
        hangStart = nil
        lastHeartbeat = now
        lastTickAt = now
        stateLock.unlock()
        // Coming back from a long gap is itself evidence the process was
        // frozen — record it here too, in case resume() lands before the next
        // tick would have noticed.
        if gap > suspensionTickGap { DiagnosticLog.noteSuspension() }
    }

    static func start() {
        let queue = DispatchQueue(label: "net.angstreich.veyrn.hangwatchdog", qos: .utility)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        source.setEventHandler { tick() }
        source.activate()
        timer = source
    }

    private static func tick() {
        // Did WE just get frozen? The timer fires every second, so a much
        // larger gap between consecutive ticks means the whole process was
        // suspended — iOS backgrounding it, or the Mac going to sleep — not
        // the main thread hanging. Scene phase can't tell us this: macOS
        // system sleep never changes it, and a BGTask-launched iOS process
        // never leaves .background. This check does, on every platform, and
        // it also covers debugger pauses.
        //
        // Build 62 shipped without it and logged 18 false hangs on the Mac
        // (654 s, 545 s, 350 s — sleep periods) and 6 more on iOS. The tell
        // was that "unresponsive" and "recovered" always shared a timestamp:
        // a real hang reports at the 3 s mark and recovers later.
        let now = Date()
        stateLock.lock()
        let paused = isPaused
        let tickGap = lastTickAt.map { now.timeIntervalSince($0) } ?? 0
        lastTickAt = now
        let wasFrozen = tickGap > suspensionTickGap
        if wasFrozen {
            lastHeartbeat = now
            isHanging = false
            hangStart = nil
        }
        stateLock.unlock()

        if wasFrozen {
            DiagnosticLog.noteSuspension()
            return
        }
        guard !paused else { return }

        pingMainThread()

        stateLock.lock()
        let elapsed = Date().timeIntervalSince(lastHeartbeat)
        let alreadyReported = isHanging
        let stillPaused = isPaused
        stateLock.unlock()

        guard !stillPaused, elapsed >= hangThreshold, !alreadyReported else { return }

        stateLock.lock()
        isHanging = true
        hangStart = lastHeartbeat
        stateLock.unlock()

        let breadcrumb = DiagnosticLog.currentBreadcrumb
        DiagnosticLog.error(String(format: "main thread unresponsive ≥%.1f s (breadcrumb: %@)", elapsed, breadcrumb))
    }

    private static func pingMainThread() {
        DispatchQueue.main.async {
            stateLock.lock()
            // A ping queued before a pause lands on resume; `pause()` clears
            // isHanging, so it can't report a bogus recovery.
            let wasHanging = isHanging && !isPaused
            let start = hangStart
            isHanging = false
            hangStart = nil
            lastHeartbeat = Date()
            stateLock.unlock()

            if wasHanging, let start {
                let elapsed = Date().timeIntervalSince(start)
                DiagnosticLog.warn(String(format: "main thread recovered after %.1f s", elapsed))
            }
        }
    }
}
