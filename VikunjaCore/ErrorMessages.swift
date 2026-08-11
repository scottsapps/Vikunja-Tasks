import Foundation

/// Plain-English explanations for the failures users actually hit.
///
/// Every message names the likely cause *and* where to fix it — the raw
/// `localizedDescription` strings ("The request timed out.", "The data
/// couldn't be read because it isn't in the correct format.") tell a user
/// nothing actionable.
enum VeyrnError {

    // MARK: - User-facing message

    static func message(for error: Error) -> String {
        if let apiError = error as? VikunjaAPI.APIError {
            return message(forStatus: apiError.statusCode)
        }
        if error is DecodingError {
            return """
            That address answered, but not like a Vikunja server. \
            Check the server address in Settings — it should be the base \
            address of your Vikunja install (for example \
            https://tasks.example.com), with no /api/v1 on the end.
            """
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return message(forURLErrorCode: ns.code) ?? ns.localizedDescription
        }
        return ns.localizedDescription
    }

    private static func message(forStatus code: Int) -> String {
        switch code {
        case 401:
            return """
            Your API token isn't valid — the server didn't recognize it. \
            The token may have been revoked, expired, or pasted \
            incompletely. In Vikunja, go to Settings → API Tokens, create a \
            new token, then paste it into Veyrn's Settings.
            """
        case 403:
            return """
            Your API token was recognized, but it doesn't have permission \
            for this. In Vikunja, check the token's permissions under \
            Settings → API Tokens — it needs read and write access to \
            projects, tasks, and labels.
            """
        case 404:
            return """
            The server didn't recognize that request. Check the server \
            address in Settings — it should be the base address of your \
            Vikunja install (for example https://tasks.example.com), with \
            no /api/v1 on the end.
            """
        case 429:
            return """
            The server is asking Veyrn to slow down. Wait a minute and try \
            again.
            """
        case 500...599:
            return """
            Your Vikunja server hit an error (HTTP \(code)). It may be \
            restarting or having trouble — try again in a few minutes. If it \
            keeps happening, check the server's own logs.
            """
        case 400...499:
            return """
            The server rejected the request (HTTP \(code)). If this keeps \
            happening, check the server address and API token in Settings.
            """
        default:
            return "The server returned an unexpected response (HTTP \(code))."
        }
    }

    private static func message(forURLErrorCode code: Int) -> String? {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return """
            Couldn't find a server at that address. Check the server address \
            in Settings for a typo. If the address is right, it may only \
            work on your home network or over VPN.
            """
        case NSURLErrorCannotConnectToHost:
            return """
            Found that address, but nothing answered. Your Vikunja server may \
            be down, or it may only be reachable on your home network or over \
            VPN.
            """
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            return """
            Couldn't make a secure connection to that server — its HTTPS \
            certificate isn't valid or has expired. Check the server address \
            in Settings, or renew the certificate on the server.
            """
        case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
            return """
            That server address isn't a valid web address. Check it in \
            Settings — it should look like https://tasks.example.com.
            """
        case NSURLErrorNotConnectedToInternet:
            return "You're not connected to the internet."
        case NSURLErrorTimedOut:
            return """
            The server didn't respond in time. It may be slow, or only \
            reachable on your home network or over VPN.
            """
        case NSURLErrorNetworkConnectionLost:
            return "The connection dropped before the server finished responding."
        case NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return "Cellular data isn't available for Veyrn right now."
        default:
            return nil
        }
    }

    // MARK: - Classification

    /// Failures caused purely by the device's connection, which resolve on
    /// their own once the network comes back. These are shown in the
    /// offline/reconnecting pill and never raised as an alert — there is
    /// nothing for the user to fix, and cached data stays on screen.
    static func isConnectivityOnly(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed
        ].contains(ns.code)
    }

    /// The connection we were using died mid-request — classically a pooled
    /// keep-alive the other end had already dropped. Distinct from the rest of
    /// `isConnectivityOnly` in that it says nothing about whether the network
    /// works: a fresh request builds a fresh connection and usually gets
    /// straight through, which is why `send(_:)` retries a GET on it rather
    /// than reporting it.
    static func isConnectionLost(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNetworkConnectionLost
    }

    /// Failures worth retrying quietly on the launch path before saying
    /// anything: everything in `isConnectivityOnly`, plus name-resolution and
    /// connection failures, which are common while Wi-Fi or a VPN is still
    /// coming up but do mean something is wrong if they persist.
    static func isRetryable(_ error: Error) -> Bool {
        if isConnectivityOnly(error) { return true }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed
        ].contains(ns.code)
    }

    /// Gateway failures: something *in front of* Vikunja — a CDN edge or the
    /// reverse proxy — answering for a server it briefly couldn't reach. The
    /// request never arrives, so Vikunja's own log stays silent and the next
    /// poll succeeds seconds later. An unattended refresh treats these like a
    /// connectivity blip rather than interrupting with an alert.
    ///
    /// A 500 is deliberately excluded: that's Vikunja itself erroring, which
    /// won't fix itself and is worth saying out loud. Confirmed in the wild
    /// (2026-08-06): a Cloudflare edge 30 miles from the user returned 502 in
    /// 2 ms — far too fast to have consulted the origin — and the same refresh
    /// went through untouched 24 seconds later.
    static func isGatewayFailure(_ error: Error) -> Bool {
        guard let apiError = error as? VikunjaAPI.APIError else { return false }
        return [502, 503, 504].contains(apiError.statusCode)
    }

    /// `NSURLErrorCancelled` (-999) — the app cancelled its own request, by
    /// quitting mid-refresh, switching accounts, or tearing down a session.
    /// Nothing failed, so it must never alert and never light the offline
    /// pill. Seen in the first real Mac log as
    /// `refresh failed: URLError(-999) [alerting]` on app quit — harmless
    /// there only because the app was already going away.
    static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    // MARK: - Diagnostic log rendering

    /// Bounded, privacy-safe error description for `DiagnosticLog` —
    /// `APIError.badStatus(401)`, `URLError(-1009)`,
    /// `DecodingError.keyNotFound(due_date)`. Never use
    /// `error.localizedDescription` in a log line: NSURLErrorDomain messages
    /// can embed the request's hostname.
    static func logDescription(for error: Error) -> String {
        if let apiError = error as? VikunjaAPI.APIError {
            return "APIError.badStatus(\(apiError.statusCode))"
        }
        if let decodingError = error as? DecodingError {
            return logDescription(forDecodingError: decodingError)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "URLError(\(ns.code))"
        }
        return "\(type(of: error))"
    }

    private static func logDescription(forDecodingError error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "DecodingError.keyNotFound(\(key.stringValue))"
        case .typeMismatch(let type, let context):
            let key = context.codingPath.last?.stringValue ?? "root"
            return "DecodingError.typeMismatch(\(key): expected \(type))"
        case .valueNotFound(let type, let context):
            let key = context.codingPath.last?.stringValue ?? "root"
            return "DecodingError.valueNotFound(\(key): expected \(type))"
        case .dataCorrupted(let context):
            let key = context.codingPath.last?.stringValue ?? "root"
            return "DecodingError.dataCorrupted(\(key))"
        @unknown default:
            return "DecodingError.unknown"
        }
    }
}
