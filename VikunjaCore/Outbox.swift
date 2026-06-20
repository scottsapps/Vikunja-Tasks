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

    private let opsKey = "vikunja.outbox.v1"
    private let counterKey = "vikunja.outbox.placeholderCounter.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
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
