import Testing
import Foundation
@testable import Veyrn

@Suite("Offline subtasks")
struct TaskMergerTests {

    private func payload(_ title: String) -> CreatePayload {
        CreatePayload(title: title, projectId: 1, description: nil, dueDate: nil, priority: nil,
                      labels: [], reminders: [], repeatAfter: nil, repeatMode: nil)
    }

    private func create(_ title: String, _ uuid: UUID, _ pid: Int) -> PendingOp {
        PendingOp(id: UUID(), timestamp: Date(), ref: .client(uuid),
                  kind: .create(payload: payload(title), placeholderId: pid))
    }

    private func relation(_ p: UUID, _ c: UUID, add: Bool = true) -> PendingOp {
        PendingOp(id: UUID(), timestamp: Date(), ref: .client(p),
                  kind: .relation(parentRef: .client(p), childRef: .client(c), kind: "subtask", add: add))
    }

    @Test("remap rewrites relation refs and keeps the op id")
    func remapRelation() {
        let suite = "TaskMergerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = Outbox(defaults: defaults)
        let p = UUID(), c = UUID(), other = UUID()
        let rel = relation(p, c)
        outbox.append(rel)
        outbox.append(create("x", other, -9))
        outbox.remap(client: p, toServer: 10)
        outbox.remap(client: c, toServer: 11)
        let got = outbox.ops.first { $0.id == rel.id }
        guard case .relation(let pr, let cr, _, _)? = got?.kind else {
            Issue.record("relation op missing"); return
        }
        #expect(pr == .server(10))
        #expect(cr == .server(11))
        #expect(outbox.ops.count == 2)
        if case .client(let u) = outbox.ops[1].ref { #expect(u == other) } else { Issue.record("unrelated op changed") }
    }

    @Test("queued child attaches to parent and is marked a subtask")
    func mergeAdd() {
        let p = UUID(), c = UUID()
        let merged = TaskMerger.merge(serverTasks: [], ops: [create("P", p, -1), create("C", c, -2), relation(p, c)])
        let parent = merged.first { $0.id == -1 }
        let child = merged.first { $0.id == -2 }
        #expect(parent?.subtasks.count == 1)
        #expect(child?.isSubtask == true)
        #expect(parent?.isSubtask == false)
    }

    @Test("relation removal clears both sides")
    func mergeRemove() {
        let p = UUID(), c = UUID()
        let merged = TaskMerger.merge(serverTasks: [], ops: [
            create("P", p, -1), create("C", c, -2), relation(p, c), relation(p, c, add: false)])
        #expect(merged.first { $0.id == -1 }?.subtasks.isEmpty == true)
        #expect(merged.first { $0.id == -2 }?.isSubtask == false)
    }
}
