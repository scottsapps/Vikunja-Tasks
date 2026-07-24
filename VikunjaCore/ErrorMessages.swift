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
}
