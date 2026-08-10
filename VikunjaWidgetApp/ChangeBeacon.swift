import CloudKit
import CryptoKit
import Foundation

/// A silent, content-only CloudKit signal so a change made on one device
/// nudges another device to sync sooner than its next poll — the fix for
/// completing a task on the Mac while the phone's already-armed reminder
/// still fires (see plan §1). Lives entirely in the user's own private
/// database (`CKContainer.default().privateCloudDatabase`, which CloudKit
/// partitions per iCloud account); Veyrn never sees another user's beacons
/// and Scott operates no server for this. Carries no task data — see the
/// four fields below.
///
/// Must never be able to break the app: every CloudKit call is wrapped so a
/// throw here can't propagate into a mutation path, and `disabledForSession`
/// gives up permanently (until relaunch) rather than retrying into a wall.
enum ChangeBeacon {

    private static let recordType = "ChangeBeacon"
    private static let subscriptionId = "veyrn-beacon-v1"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: VikunjaConfig.appGroupSuite) }

    private static let deviceIdKey = "veyrn.beacon.deviceId"
    private static let subscribedFlagKey = "veyrn.beacon.subscribedV2"
    private static let staleSubscribedFlagKeyV1 = "veyrn.beacon.subscribedV1"

    /// Set once per session on an unrecoverable CloudKit condition (no iCloud
    /// account, push registration failure, or repeated `CKError`s). Once set,
    /// `publish` and `registerForNudges` are no-ops until relaunch — this
    /// feature degrades to today's polling behavior, silently, with no user
    /// action possible or needed.
    private(set) static var disabledForSession = false

    static func disableForSession(reason: String) {
        guard !disabledForSession else { return }
        disabledForSession = true
        DiagnosticLog.info("nudge disabled for session: \(reason)")
    }

    // MARK: - Device identity

    private static var cachedDeviceId: String?

    private static var deviceId: String {
        if let cached = cachedDeviceId { return cached }
        let d = defaults
        // Build 72 could set this on a schema rejection it misread as
        // "already installed", which then blocked every future retry — see
        // `references/app.md`. The V2 key name plus this one-time removal is
        // what lets those installs retry without a reinstall.
        d?.removeObject(forKey: staleSubscribedFlagKeyV1)
        if let existing = d?.string(forKey: deviceIdKey) {
            cachedDeviceId = existing
            return existing
        }
        let new = UUID().uuidString
        d?.set(new, forKey: deviceIdKey)
        cachedDeviceId = new
        return new
    }

    // MARK: - Account identity

    /// A stable, cross-device, non-reversible handle for "which Vikunja account this
    /// is". `VeyrnAccount.id` is generated per install and differs between devices,
    /// so it cannot be used here. The host is hashed rather than stored: the beacon
    /// lives in the user's own private database, but Veyrn's standing rule is that a
    /// hostname is identifying and never leaves the device in the clear.
    ///
    /// Known collision: two accounts on the *same* host (a supported setup) share a
    /// key, so a change in one nudges a device sitting on the other. The cost is one
    /// unnecessary refresh — correct, just slightly wasteful. Accepted deliberately
    /// over inventing a second identifier.
    private static func accountKey(forHost host: String) -> String {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Send (debounced)

    private static var pendingPublishTask: Task<Void, Never>?
    private static var pendingReasons: [String] = []

    /// Fire-and-forget. Coalesces bursts (2 s debounce) so a bulk import or a
    /// rapid series of edits produces one beacon write, not thirty. A no-op
    /// when unconfigured, signed out of iCloud, or disabled this session.
    static func publish(reason: String) {
        guard VikunjaConfig.isConfigured, !VikunjaConfig.host.isEmpty, !disabledForSession else { return }
        pendingReasons.append(reason)
        pendingPublishTask?.cancel()
        pendingPublishTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await performPublish()
        }
    }

    private static func performPublish() async {
        let reasons = pendingReasons
        pendingReasons = []
        guard !reasons.isEmpty else { return }
        guard VikunjaConfig.isConfigured, !VikunjaConfig.host.isEmpty, !disabledForSession else { return }

        let key = accountKey(forHost: VikunjaConfig.host)
        // A fresh record + `.allKeys` savePolicy each time is the CloudKit
        // upsert pattern: it overwrites regardless of the existing record's
        // change tag, so concurrent writes from two devices can never surface
        // a conflict we'd have to resolve.
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: "beacon-\(key)"))
        record["accountKey"] = key as CKRecordValue
        record["deviceId"] = deviceId as CKRecordValue
        record["changedAt"] = Date() as CKRecordValue
        #if os(iOS)
        record["origin"] = "ios" as CKRecordValue
        #else
        record["origin"] = "macos" as CKRecordValue
        #endif

        do {
            let (saveResults, _) = try await CKContainer.default().privateCloudDatabase.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys
            )
            // CloudKit reports per-record failures inside the result rather than by
            // throwing, so a discarded result turns "record type not found" into a
            // logged success (build 72). Rethrow into the catch below instead.
            for (_, result) in saveResults {
                if case .failure(let error) = result { throw error }
            }
            DiagnosticLog.info("nudge sent (reason: \(reasons.joined(separator: ", ")))")
        } catch {
            DiagnosticLog.warn("nudge send failed: \(describe(error))")
            noteFailure(error)
        }
    }

    // MARK: - Subscription

    /// Idempotent. Called once per launch from each app target. Silent
    /// (`content-available`) pushes don't require notification permission, so
    /// this must not be gated on `ReminderScheduler.requestPermission()`.
    ///
    /// Expected to fail until Scott marks `ChangeBeacon.recordName` Queryable
    /// in the CloudKit Console (plan §B1 step 3) — that's a normal, silent
    /// degradation, not a bug to work around here.
    static func registerForNudges() {
        guard !disabledForSession else { return }
        guard defaults?.bool(forKey: subscribedFlagKey) != true else { return }

        Task {
            let database = CKContainer.default().privateCloudDatabase

            // Ask rather than infer. Classifying CloudKit error codes to guess
            // "already exists" is what let a schema rejection masquerade as a
            // successful install in build 72 — and the sticky flag then made it
            // permanent. `subscription(for:)` throws `.unknownItem` when absent
            // rather than returning nil, so that specific error means "proceed
            // to create it"; any other error means "we don't know, don't guess".
            do {
                _ = try await database.subscription(for: subscriptionId)
                defaults?.set(true, forKey: subscribedFlagKey)
                DiagnosticLog.info("nudge subscription already present")
                return
            } catch let ckError as CKError where ckError.code == .unknownItem {
                // Absent — fall through and create it below.
            } catch {
                DiagnosticLog.warn("nudge subscription check failed: \(describe(error))")
                noteFailure(error)
                return
            }

            let subscription = CKQuerySubscription(
                recordType: recordType,
                predicate: NSPredicate(value: true),
                subscriptionID: subscriptionId,
                options: [.firesOnRecordCreation, .firesOnRecordUpdate]
            )
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            info.shouldBadge = false
            // Carry the fields in the payload so the receiving device doesn't need a
            // fetch round trip just to decide whether to ignore its own beacon.
            info.desiredKeys = ["accountKey", "deviceId", "changedAt"]
            subscription.notificationInfo = info

            do {
                _ = try await database.save(subscription)
                defaults?.set(true, forKey: subscribedFlagKey)
                DiagnosticLog.info("nudge subscription installed")
            } catch {
                // Never set the flag on failure: the retry on next launch is the
                // whole recovery path once the schema is deployed.
                DiagnosticLog.warn("nudge subscription failed: \(describe(error))")
                noteFailure(error)
            }
        }
    }

    // MARK: - Receive

    /// In-memory only — a receive-side rate limit, not a persisted cursor.
    private static var lastNudgeSyncAt: Date?

    /// Returns true if the payload was a Veyrn beacon this device should act on.
    /// Callers use the return value to decide whether to sync.
    static func shouldSync(forRemoteNotification userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let query = notification as? CKQueryNotification,
              query.subscriptionID == subscriptionId else {
            return false
        }

        let fields = query.recordFields ?? [:]

        // CloudKit's behaviour on notifying the originating device is not
        // contractually guaranteed either way, so this is what prevents a
        // self-wake loop — do not remove it as redundant.
        if let remoteDeviceId = fields["deviceId"] as? String, remoteDeviceId == deviceId {
            DiagnosticLog.info("nudge ignored (self)")
            return false
        }

        // Missing/unreadable → fail open: an unnecessary refresh is harmless;
        // a missed one is the bug this feature exists to fix.
        if let remoteAccountKey = fields["accountKey"] as? String {
            let ourKey = accountKey(forHost: VikunjaConfig.host)
            if remoteAccountKey != ourKey {
                DiagnosticLog.info("nudge ignored (other account)")
                return false
            }
        }

        if let last = lastNudgeSyncAt, Date().timeIntervalSince(last) < 5 {
            DiagnosticLog.info("nudge ignored (rate limit)")
            return false
        }
        lastNudgeSyncAt = Date()
        DiagnosticLog.info("nudge received")
        return true
    }

    // MARK: - Error description

    /// CKError's `localizedDescription` can carry container and account detail, so
    /// it never reaches the log. The numeric code is what's actually diagnosable
    /// (11 = unknownItem/missing record type, 15 = serverRejectedRequest — the two
    /// most likely here, but log the number rather than hardcoding interpretations).
    private static func describe(_ error: Error) -> String {
        if let ck = error as? CKError { return "CKError \(ck.errorCode)" }
        return VeyrnError.logDescription(for: error)
    }

    // MARK: - Failure bookkeeping

    private static var ckErrorCount = 0

    private static func noteFailure(_ error: Error) {
        guard let ckError = error as? CKError else { return }
        switch ckError.code {
        case .notAuthenticated: disableForSession(reason: "notAuthenticated")
        case .managedAccountRestricted: disableForSession(reason: "managedAccountRestricted")
        case .permissionFailure: disableForSession(reason: "permissionFailure")
        default:
            ckErrorCount += 1
            if ckErrorCount >= 3 {
                disableForSession(reason: "repeated CKError")
            }
        }
    }
}
