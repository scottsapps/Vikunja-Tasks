# Plan: create a task with subtasks while offline

Status: **not implemented**. Written 2026-11-07 for an implementing session.

## Before you start

- Load the `vikunja-widget` skill and read `references/core.md` (outbox,
  offline model) and `references/app.md` (QuickAddSheet, Pending Changes,
  discard cascade) before you edit anything.
- Line numbers below are from the time of writing; re-locate by
  symbol name if they've drifted.
- Keep changes to what this plan lists. Don't refactor the drain loop.

## The problem

In Quick Add, a task **without** subtasks goes through the outbox
(`store.createTask`) and works offline. A task **with** subtasks takes a
separate, direct-API path that refuses to run offline:

`VikunjaWidgetApp/QuickAddSheet.swift`, `submit()` (~lines 748–791):

```swift
} else {
    guard store.reachability.isOnline else {
        errorMessage = "Go online to add subtasks."
        ...
    }
    let created = try await VikunjaAPI.createTask(...)
    for subTitle in pendingSubtasks {
        let sub = try await VikunjaAPI.createTask(projectId: project.id, title: subTitle)
        try await VikunjaAPI.addRelation(taskId: created.id, otherTaskId: sub.id, kind: "subtask")
        ...
    }
```

## What already exists (don't rebuild it)

- `PendingOp.Kind.relation(parentRef:childRef:kind:add:)` —
  `VikunjaCore/Outbox.swift:24`. Refs can be `.client(UUID)` (not yet created).
- The drain sends `.relation` ops once both refs are `.server` —
  `TaskStore.performDrainPass()`, `case .relation` (~line 1190). Unresolved
  refs → `continue` (op stays queued, retried next pass).
- `TaskMerger.merge` attaches a queued child under its parent's
  `relatedTasks["subtask"]` — `VikunjaCore/TaskMerger.swift:40`.
- Pending Changes already labels relation ops ("Subtask link",
  `TaskStore.swift` ~1339).
- `opsRemovedTogether(with:)` (`TaskStore.swift` ~1424) already cascades a
  discarded `.create` to any `.relation` naming it as parent or child.
- Bulk create (`bulkCreateRun` / `performBulkCreate`, ~1538–1578) remaps
  each created op's client ref via `outbox.remap`.

**Nothing in the codebase ever enqueues a `.relation` op.** That's the
missing producer — plus the remap bug in step 1, which the producer would
immediately hit.

## Steps

### 1. Fix `Outbox.remap` to rewrite relation refs (required)

`VikunjaCore/Outbox.swift:105`:

```swift
func remap(client uuid: UUID, toServer id: Int) {
    for index in ops.indices {
        if case .client(let opUUID) = ops[index].ref, opUUID == uuid {
            ops[index].ref = .server(id)
        }
    }
    persist()
}
```

This only updates `op.ref`. A `.relation` op carries its targets in
`parentRef`/`childRef` (its `ref` is just a copy of the parent's), so after
the parent and child are created the relation still holds `.client` refs,
`serverId(for:)` returns nil, and the drain `continue`s forever — a permanent
"1 pending" that never sends and never fails.

Fix: `kind` is `let`, so rebuild the op. In the same loop, if
`ops[index].kind` is `.relation(p, c, k, add)` and `p` or `c` is
`.client(uuid)`, replace the op with a new `PendingOp` that has the **same
`id` and `timestamp`**, `ref` remapped the same way, and
`kind: .relation(parentRef: remapped(p), childRef: remapped(c), kind: k, add: add)`.
Easiest: make `kind` a `var` in `PendingOp` (it's `Codable`; changing
`let`→`var` doesn't change the encoding, so persisted queues still decode),
then assign in place. Persist once at the end as today.

### 2. Make `createTask` return the task's ref

`TaskStore.createTask(...)` (~line 744) returns the op's `UUID?`. Subtask
linking needs the task's `TaskRef` (`.client(clientId)`).

Split it: move the body into a private
`enqueueCreate(payload: CreatePayload) -> (opId: UUID, ref: TaskRef)` that
appends the op and does **not** call `rebuildMergedTasks()`, telemetry, or
start a drain. `createTask` keeps its public signature and return value: it
does the read-only check, builds the payload, calls `enqueueCreate`, then
rebuild + `TaskCreated` signal + `Task { await drainOutbox() }` as today.
Every existing caller stays unchanged.

### 3. Add `TaskStore.createTaskWithSubtasks`

```swift
@discardableResult
func createTaskWithSubtasks(
    projectId: Int, title: String, description: String?, dueDate: Date?,
    priority: Int?, labels: [VikunjaLabel], reminders: [Date],
    repeatAfter: Int?, repeatMode: Int?,
    subtaskTitles: [String], source: String
) -> UUID?   // parent create's op id, nil if refused
```

- `guard !refuseIfReadOnly(projectId:action: "create") else { return nil }` — once.
- Enqueue the parent create, then **all** subtask creates (same `projectId`,
  title only — matches today's online path), then **all** relation ops
  `.relation(parentRef: parentRef, childRef: childRef, kind: "subtask", add: true)`
  with the op's `ref` set to `parentRef`.
- **Order matters:** creates first, then relations. `bulkCreateRun` only
  coalesces *consecutive* same-project creates; interleaving relations would
  split one bulk request into many.
- Do every enqueue synchronously with **no `await`** in between, then a single
  `rebuildMergedTasks()`, then `Task { await drainOutbox() }`. (A drain that
  started mid-sequence would still be correct — relations would wait a pass —
  but this keeps it to one bulk request.)
- Telemetry: `TaskCreated` once and `SubtaskAdded` once per subtask, both with
  `source`, matching the current online path. Don't call
  `ChangeBeacon.publish` here — the drain already publishes after ops land.

### 4. Call it from `QuickAddSheet`

Replace the whole `else { ... }` branch (~761–791) with a call to
`store.createTaskWithSubtasks(...)` passing the same values the
no-subtask branch passes plus `subtaskTitles: pendingSubtasks`. Delete the
`isOnline` guard and the `"Go online to add subtasks."` message.

Use the outbox path online too (one code path, same as tasks without
subtasks). Trade-off, accepted: a server error no longer appears inline in the
sheet; it surfaces through the drain's normal error handling, exactly as it
already does for a task without subtasks.

### 5. Hide queued subtasks from top-level lists before sync

`VikunjaModels.isSubtask` checks `relatedTasks["parenttask"]`. Top-level
lists (`TaskStore` ~191–200) filter on it. `TaskMerger`'s `.relation` case
only edits the parent, so until the next refresh each offline subtask also
shows up as a standalone task in Inbox/Project/Today.

In `TaskMerger.swift`'s `.relation` case, when `kind == "subtask"`, also
update the child: on `add`, set `child.relatedTasks["parenttask"]` to
contain the parent (no duplicates); on remove, take the parent out (and set
the key/dictionary to nil when empty, as the parent side does). Write the
child back to `byId[childId]`. Do this **after** updating the parent, so the
copy of the child stored in the parent's subtask list is the one without the
back-reference (avoids a recursive-looking structure).

### 6. Discard behaviour — leave as is

Discarding the queued parent already removes its relation ops; the child
creates survive and land as ordinary standalone tasks. That's acceptable and
needs no code. Don't add grouping.

### 7. (Optional, separate commit) Inline editor `addSubtask`

`InlineTaskEditor.swift:752` `addSubtask()` is also direct-API and silently
no-ops for an unsynced parent (`task.id > 0`). Only do this if steps 1–6 are
done and verified. Same pattern: add a `TaskStore.addSubtask(to parent:
VikunjaTask, title:)` that enqueues a child create + a `.relation` op using
`ref(for: parent.id)` (the existing helper at ~line 1690, which returns
`.client` for negative placeholder ids), and have the editor's subtask list
read from the merged task in `store.undoneTasks` instead of only
`loadedSubtasks`. If this grows, stop and leave it for a follow-up.

## Invariants to respect

- Don't touch v1/v2 update routing. Relations use the relation endpoint, not
  a task update, so the "v1 updates must send the full task" rule isn't
  involved.
- Bulk create is the only replayable mutation; don't add retries elsewhere.
- No new user-facing strings are expected. If you add any, write them as
  `Text`/`Button` literals and run `make strings`. The removed
  `"Go online to add subtasks."` was a plain `String`, so it likely isn't in
  the catalog — check `VikunjaCore/Localizable.xcstrings` and remove it if
  it is.
- `DiagnosticLog`: no titles or user content in log lines (ids only).

## Tests

The only test target is `VeyrnCalendarTests` (macOS, hosted by the app via
`TEST_HOST` — see `references/calendar.md`). Add a `TaskMergerTests.swift`
there if `TaskMerger`/`Outbox` are reachable via `@testable import`;
if not, don't restructure targets — note it and rely on the manual test.

- `Outbox.remap` rewrites `.client` parent/child refs inside a `.relation`
  op, keeps the op's `id`, and leaves unrelated ops untouched.
- `TaskMerger`: parent create + child create + relation → parent's
  `subtasks` contains the child, and the child's `isSubtask == true`.
- `TaskMerger`: relation with `add: false` removes both sides.

## Verify

```bash
make gen
xcodebuild -project VikunjaWidget.xcodeproj -scheme VikunjaWidgetApp \
  -derivedDataPath /tmp/veyrn-sanity -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
# also the iOS and watchOS sanity builds from the skill
xcodebuild test -project VikunjaWidget.xcodeproj -scheme VikunjaWidgetApp \
  -derivedDataPath /tmp/veyrn-test -destination 'platform=macOS'
```

Manual check (signed build, not the unsigned sanity build):

1. Turn off networking. Quick Add a task with two subtasks (expanded sheet).
   The sheet closes; the parent shows with a 0/2 subtask count; the
   subtasks do **not** appear as separate top-level rows; Pending Changes
   shows 3 creates + 2 "Subtask link" rows.
2. Turn networking on. Pending Changes drains to 0 (not stuck at 2 — that
   would mean step 1 isn't working). The web UI shows both subtasks under the
   parent.
3. Repeat offline, then discard the parent in Pending Changes: the two link
   rows go with it; the two subtasks remain as standalone queued tasks.
4. Online: Quick Add with subtasks still works and lands immediately.

Commit steps 1–6 together; step 7 separately if done.
