import Foundation

/// Pure reconciler: applies queued ops on top of a server-fetched task list.
enum TaskMerger {

    static func merge(
        serverTasks: [VikunjaTask],
        ops: [PendingOp],
        labelDirectory: [Int: VikunjaLabel] = [:]
    ) -> [VikunjaTask] {
        var byId: [Int: VikunjaTask] = [:]
        for task in serverTasks { byId[task.id] = task }

        // Track which client UUID maps to which placeholder ID for in-merge lookup.
        var placeholderByClient: [UUID: Int] = [:]

        for op in ops {
            switch op.kind {
            case .create(let payload, let placeholderId):
                if case .client(let uuid) = op.ref {
                    placeholderByClient[uuid] = placeholderId
                }
                byId[placeholderId] = synthesize(payload: payload, placeholderId: placeholderId)

            case .update(let update):
                guard let id = resolveId(op.ref, placeholderByClient: placeholderByClient),
                      let existing = byId[id] else { continue }
                byId[id] = apply(update: update, to: existing, labelDirectory: labelDirectory)

            case .complete:
                guard let id = resolveId(op.ref, placeholderByClient: placeholderByClient),
                      let existing = byId[id] else { continue }
                byId[id] = setDone(existing, done: true)

            case .reopen:
                guard let id = resolveId(op.ref, placeholderByClient: placeholderByClient),
                      let existing = byId[id] else { continue }
                byId[id] = setDone(existing, done: false)
            }
        }

        return Array(byId.values)
    }

    // MARK: - Private helpers

    private static func resolveId(
        _ ref: TaskRef,
        placeholderByClient: [UUID: Int]
    ) -> Int? {
        switch ref {
        case .server(let id): return id
        case .client(let uuid): return placeholderByClient[uuid]
        }
    }

    private static func synthesize(payload: CreatePayload, placeholderId: Int) -> VikunjaTask {
        let formatter = ISO8601DateFormatter()
        let dueString = payload.dueDate.map { formatter.string(from: $0) }
        let reminders = payload.reminders.map {
            VikunjaReminder(reminder: formatter.string(from: $0))
        }
        return VikunjaTask(
            id: placeholderId,
            title: payload.title,
            done: false,
            dueDate: dueString,
            projectId: payload.projectId,
            labels: payload.labels.isEmpty ? nil : payload.labels,
            description: nil,
            updated: nil,
            priority: payload.priority,
            reminders: reminders.isEmpty ? nil : reminders
        )
    }

    private static func apply(
        update: TaskUpdate,
        to task: VikunjaTask,
        labelDirectory: [Int: VikunjaLabel]
    ) -> VikunjaTask {
        let formatter = ISO8601DateFormatter()
        var newDue = task.dueDate
        if update.clearDueDate {
            newDue = nil
        } else if let d = update.dueDate {
            newDue = formatter.string(from: d)
        }

        var newPriority = task.priority
        if update.clearPriority {
            newPriority = nil
        } else if let p = update.priority {
            newPriority = p
        }

        var newLabels = task.labels
        if let ids = update.labelIds {
            // Resolve names from existing task labels first, falling back to directory.
            var lookup: [Int: VikunjaLabel] = [:]
            for label in task.labels ?? [] { lookup[label.id] = label }
            for (id, label) in labelDirectory { lookup[id] = label }
            newLabels = ids.map { lookup[$0] ?? VikunjaLabel(id: $0, title: "") }
        }

        var newReminders = task.reminders
        if let dates = update.reminders {
            newReminders = dates.map { VikunjaReminder(reminder: formatter.string(from: $0)) }
        }

        return VikunjaTask(
            id: task.id,
            title: update.title ?? task.title,
            done: task.done,
            dueDate: newDue,
            projectId: update.projectId ?? task.projectId,
            labels: newLabels,
            description: update.description ?? task.description,
            updated: task.updated,
            priority: newPriority,
            reminders: newReminders
        )
    }

    private static func setDone(_ task: VikunjaTask, done: Bool) -> VikunjaTask {
        VikunjaTask(
            id: task.id,
            title: task.title,
            done: done,
            dueDate: task.dueDate,
            projectId: task.projectId,
            labels: task.labels,
            description: task.description,
            updated: task.updated,
            priority: task.priority,
            reminders: task.reminders
        )
    }
}
