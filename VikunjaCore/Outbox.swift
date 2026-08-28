import Foundation
import Observation

// MARK: - Operation reference

enum TaskRef: Codable, Hashable {
    case server(Int)
    case client(UUID)
}

// MARK: - Pending operation

struct PendingOp: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    var ref: TaskRef
    let kind: Kind

    enum Kind: Codable {
        case create(payload: CreatePayload, placeholderId: Int)
        case update(update: TaskUpdate)
        case complete
        case reopen
        case relation(parentRef: TaskRef, childRef: TaskRef, kind: String, add: Bool)
    }
}

struct CreatePayload: Codable {
    let title: String
    let projectId: Int
    let description: String?
    let dueDate: Date?
    let priority: Int?
    let labels: [VikunjaLabel]
    let reminders: [Date]
    let repeatAfter: Int?
    let repeatMode: Int?
}

// MARK: - Outbox

@Observable
final class Outbox {
    private(set) var ops: [PendingOp] = []
    private var nextPlaceholder: Int = -1

    private static let legacyOpsKey = "vikunja.outbox.v1"
    private static let legacyCounterKey = "vikunja.outbox.placeholderCounter.v1"

    private let opsKey: String
    private let counterKey: String
    private let defaults: UserDefaults

    /// `accountId` nil = no account (fresh install) — falls back to the legacy
    /// unsuffixed keys with nothing to migrate.
    init(defaults: UserDefaults = .standard, accountId: UUID? = nil) {
        self.defaults = defaults
        if let accountId {
            self.opsKey = "\(Self.legacyOpsKey).\(accountId.uuidString)"
            self.counterKey = "\(Self.legacyCounterKey).\(accountId.uuidString)"
        } else {
            self.opsKey = Self.legacyOpsKey
            self.counterKey = Self.legacyCounterKey
        }
        migrateLegacyIfNeeded()
        load()
    }

    /// One-time migration for a user who updates while offline with queued
    /// outbox ops: the pre-multi-account keys are unsuffixed, so copy them
    /// across to this (necessarily the just-migrated legacy) account's keys
    /// and remove the old ones. A no-op once this has run, since the legacy
    /// keys are gone afterward.
    private func migrateLegacyIfNeeded() {
        guard opsKey != Self.legacyOpsKey else { return }
        guard defaults.data(forKey: opsKey) == nil else { return }
        guard let legacyData = defaults.data(forKey: Self.legacyOpsKey) else { return }
        defaults.set(legacyData, forKey: opsKey)
        if defaults.object(forKey: Self.legacyCounterKey) != nil {
            defaults.set(defaults.integer(forKey: Self.legacyCounterKey), forKey: counterKey)
        }
        defaults.removeObject(forKey: Self.legacyOpsKey)
        defaults.removeObject(forKey: Self.legacyCounterKey)
    }

    // MARK: - Mutations

    func append(_ op: PendingOp) {
        ops.append(op)
        persist()
    }

    func remove(id: UUID) {
        ops.removeAll { $0.id == id }
        persist()
    }

    /// Drops every queued op in one write — the "Discard All" path. Looping
    /// `remove(id:)` would re-encode and re-persist once per op.
    func removeAll() {
        ops.removeAll()
        persist()
    }

    func remap(client uuid: UUID, toServer id: Int) {
        for index in ops.indices {
            if case .client(let opUUID) = ops[index].ref, opUUID == uuid {
                ops[index].ref = .server(id)
            }
        }
        persist()
    }

    /// Reserves the next negative placeholder ID for an offline-created task.
    func nextPlaceholderId() -> Int {
        let next = nextPlaceholder
        nextPlaceholder -= 1
        persist()
        return next
    }

    /// Reverse-lookup helper: finds the client UUID for a placeholder task id.
    func clientId(forPlaceholder taskId: Int) -> UUID? {
        for op in ops {
            if case .create(_, let pid) = op.kind, pid == taskId,
               case .client(let uuid) = op.ref {
                return uuid
            }
        }
        return nil
    }

    /// Forward-lookup helper: the negative placeholder id reserved for an
    /// offline-created task, by its client UUID. Used when resolving a queued
    /// op back to the row it targets in the merged task list.
    func placeholderId(forClient uuid: UUID) -> Int? {
        for op in ops {
            if case .client(let opUUID) = op.ref, opUUID == uuid,
               case .create(_, let pid) = op.kind {
                return pid
            }
        }
        return nil
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: opsKey),
           let decoded = try? JSONDecoder().decode([PendingOp].self, from: data) {
            ops = decoded
        }
        let stored = defaults.integer(forKey: counterKey)
        if stored < 0 {
            nextPlaceholder = stored
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(ops) {
            defaults.set(data, forKey: opsKey)
        }
        defaults.set(nextPlaceholder, forKey: counterKey)
    }
}
