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
        stateLock.lock()
        isPaused = false
        isHanging = false
        hangStart = nil
        lastHeartbeat = Date()
        stateLock.unlock()
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
        stateLock.lock()
        let paused = isPaused
        stateLock.unlock()
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
