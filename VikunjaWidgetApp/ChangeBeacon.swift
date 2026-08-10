import CloudKit
import CryptoKit
import Foundation

/// A silent, content-only CloudKit signal so a change made on one device
/// nudges another device to sync sooner than its next poll — the fix for
/// completing a task on the Mac while the phone's already-armed reminder
/// still fires (see plan §1). Lives entirely in the user's own private
/// database (`CKContainer.default().privateCloudDatabase`, which CloudKit
/// partitions per iCloud account), in a custom zone (`VeyrnBeaconZone`) —
/// database/zone subscriptions are refused outright in the default zone, see
/// `references/app.md`. Veyrn never sees another user's beacons and Scott
/// operates no server for this. Carries no task data — see the four fields
/// below.
///
/// Must never be able to break the app: every CloudKit call is wrapped so a
/// throw here can't propagate into a mutation path, and `disabledForSession`
/// gives up permanently (until relaunch) rather than retrying into a wall.
enum ChangeBeacon {

    private static let recordType = "ChangeBeacon"
    private static let subscriptionId = "veyrn-beacon-v2"
    private static let staleSubscriptionIdV1 = "veyrn-beacon-v1"

    private static let zoneName = "VeyrnBeaconZone"
    private static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: VikunjaConfig.appGroupSuite) }

    private static let deviceIdKey = "veyrn.beacon.deviceId"
    private static let subscribedFlagKey = "veyrn.beacon.subscribedV3"
    private static let staleSubscribedFlagKeyV1 = "veyrn.beacon.subscribedV1"
    private static let staleSubscribedFlagKeyV2 = "veyrn.beacon.subscribedV2"
    private static let v1SubscriptionCleanupDoneKey = "veyrn.beacon.v1SubscriptionCleanedUp"
    private static let lastSeenAtKey = "veyrn.beacon.lastSeenAt"

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
        // Build 72 could set the V1 flag on a schema rejection it misread as
        // "already installed"; build 74's move to a custom zone + database
        // subscription obsoletes V2 the same way. Both stale keys are removed
        // once per launch so any install poisoned by either generation starts
        // retrying against the current subscription without a reinstall — see
        // `references/app.md`.
        d?.removeObject(forKey: staleSubscribedFlagKeyV1)
        d?.removeObject(forKey: staleSubscribedFlagKeyV2)
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

    // MARK: - Zone

    /// One round trip per session — database/zone subscriptions and every
    /// beacon record live in this zone, never the default zone (which
    /// rejects them outright with `invalidArguments`, confirmed build 73).
    /// Re-saving a zone that already exists succeeds like any other save, so
    /// there's no separate "already exists" case to special-case here — the
    /// same "ask, don't guess" rule as the subscription-existence check below.
    private static var zoneVerified = false

    private static func ensureZoneExists() async throws {
        guard !zoneVerified else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        let (saveResults, _) = try await CKContainer.default().privateCloudDatabase.modifyRecordZones(
            saving: [zone], deleting: []
        )
        // Same trap as `modifyRecords`: a rejected zone save comes back as a
        // `.failure` inside the result, not by throwing. Discarding it would
        // repeat build 72's false "success" — see `references/app.md`.
        for (_, result) in saveResults {
            if case .failure(let error) = result { throw error }
        }
        zoneVerified = true
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

        do {
            try await ensureZoneExists()
        } catch {
            DiagnosticLog.warn("nudge zone failed: \(describe(error))")
            noteFailure(error)
            return
        }

        let key = accountKey(forHost: VikunjaConfig.host)
        // A fresh record + `.allKeys` savePolicy each time is the CloudKit
        // upsert pattern: it overwrites regardless of the existing record's
        // change tag, so concurrent writes from two devices can never surface
        // a conflict we'd have to resolve.
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: "beacon-\(key)", zoneID: zoneID)
        )
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
    /// A `CKDatabaseSubscription` scoped to `recordType` — no predicate, no
    /// `desiredKeys`, no queryable index required. Database/zone subscriptions
    /// only fire in a custom zone, hence `ensureZoneExists()` first.
    static func registerForNudges() {
        guard !disabledForSession else { return }
        guard defaults?.bool(forKey: subscribedFlagKey) != true else { return }

        Task {
            do {
                try await ensureZoneExists()
            } catch {
                DiagnosticLog.warn("nudge zone failed: \(describe(error))")
                noteFailure(error)
                return
            }

            let database = CKContainer.default().privateCloudDatabase

            // Best-effort, one time: any install that succeeded in creating the
            // old query subscription would otherwise keep receiving its pushes
            // forever alongside the new one. Scott's console shows none exists,
            // but this covers any other install that did succeed.
            if defaults?.bool(forKey: v1SubscriptionCleanupDoneKey) != true {
                _ = try? await database.deleteSubscription(withID: staleSubscriptionIdV1)
                defaults?.set(true, forKey: v1SubscriptionCleanupDoneKey)
            }

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

            let subscription = CKDatabaseSubscription(subscriptionID: subscriptionId)
            subscription.recordType = recordType   // narrow it to our own records
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true // silent push
            info.shouldBadge = false
            // No desiredKeys: database subscriptions don't carry record fields.
            // The receive path fetches the beacon instead (see `shouldSync`).
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
    ///
    /// A database subscription's push carries no record fields, so — unlike
    /// the old query subscription — this must fetch the beacon record to
    /// learn `deviceId`/`accountKey`/`changedAt`. That's one extra round trip,
    /// only when something actually changed.
    static func shouldSync(forRemoteNotification userInfo: [AnyHashable: Any]) async -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let databaseNotification = notification as? CKDatabaseNotification,
              databaseNotification.subscriptionID == subscriptionId else {
            return false
        }

        // Rate limit first, before the network call — this is what keeps a
        // burst from costing a round trip each.
        if let last = lastNudgeSyncAt, Date().timeIntervalSince(last) < 5 {
            DiagnosticLog.info("nudge ignored (rate limit)")
            return false
        }

        let key = accountKey(forHost: VikunjaConfig.host)
        let recordID = CKRecord.ID(recordName: "beacon-\(key)", zoneID: zoneID)

        let record: CKRecord
        do {
            record = try await CKContainer.default().privateCloudDatabase.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            // We have no beacon of our own for the active account, so this
            // change can't be a change to our own record.
            DiagnosticLog.info("nudge ignored (other account)")
            return false
        } catch {
            // Fail open: an unnecessary refresh is harmless; a missed one is
            // the bug this feature exists to fix. Do not call `noteFailure`
            // here — a receive-side hiccup must not count toward disabling
            // the whole feature.
            DiagnosticLog.warn("nudge fetch failed: \(describe(error))")
            return true
        }

        // CloudKit's behaviour on notifying the originating device is not
        // contractually guaranteed either way, so this is what prevents a
        // self-wake loop — do not remove it as redundant.
        if let remoteDeviceId = record["deviceId"] as? String, remoteDeviceId == deviceId {
            DiagnosticLog.info("nudge ignored (self)")
            return false
        }

        // Stops a nudge triggered by *another* account's beacon (or by our
        // own beacon write that we're the origin of) from making us re-sync
        // on our own already-seen record.
        if let changedAt = record["changedAt"] as? Date {
            if let lastSeen = defaults?.object(forKey: lastSeenAtKey) as? Date, changedAt <= lastSeen {
                DiagnosticLog.info("nudge ignored (no change)")
                return false
            }
            defaults?.set(changedAt, forKey: lastSeenAtKey)
        }

        lastNudgeSyncAt = Date()
        DiagnosticLog.info("nudge received")
        return true
    }

    // MARK: - Error description

    /// CKError's `localizedDescription` can carry container and account detail, so
    /// it never reaches the log. CloudKit also returns a server-side explanation of
    /// *why* under the `ServerErrorDescription` userInfo key — undocumented as a
    /// named constant, but bounded API/schema text, not user content, and it's what
    /// actually turns a bare "CKError 12" into an answer.
    private static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return VeyrnError.logDescription(for: error) }
        if let server = ck.userInfo["ServerErrorDescription"] as? String, !server.isEmpty {
            return "CKError \(ck.errorCode): \(server.prefix(200))"
        }
        return "CKError \(ck.errorCode)"
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
