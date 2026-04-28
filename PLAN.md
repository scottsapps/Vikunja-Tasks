# VikunjaWidget → Full App: Implementation Plan

## Goals
- Expand the existing TestFlight widget app into a full Things 3-style task app for macOS and iOS.
- Reuse the widget's API client, models, and aesthetic.
- Keep distribution personal/TestFlight only.

## Sidebar (final)
1. **Inbox** — tasks in Vikunja project named "Inbox" (verify id at fetch time, don't hardcode)
2. **Today** — combined Today + Upcoming. All undone tasks with a due date, sectioned by Today (overdue included) / Tomorrow / `EEE, MMM d`. Same logic as widget's `group()`.
3. **Logbook** — done tasks, sorted by completion date desc, paginated 50 at a time
4. **Projects** — flat list of Vikunja projects, each opens a project view

No Someday, no Anytime, no Areas grouping.

## Tag-first project view
User differentiates within a project via tags. Project view shows:
- Top: horizontal scrollable row of tag filter chips (only tags present in this project's undone tasks). Tap to toggle filter; multiple tags = AND.
- Body: same `TaskListView` grouped by date sections (Today/Tomorrow/future/no-date).

---

## Phase 0 — Code sharing setup
- Create `VikunjaCore/` directory at repo root.
- Move `VikunjaModels.swift`, `VikunjaAPI.swift`, `VikunjaConfig.swift`, `SharedState.swift` from `VikunjaWidgetExtension/` into `VikunjaCore/`.
- In `project.yml`, add `VikunjaCore` to the `sources:` list of all four targets (the two app targets and both widget extension targets).
- `make gen`, then verify the widget still builds and runs (`xcodebuild -scheme VikunjaWidgetAppIOS …`).

## Phase 1 — App shell with read-only parity
New files in `VikunjaWidgetApp/`:

- **AppRoot.swift** — `NavigationSplitView` (3-column on Mac/iPad, 2 on iPhone). Holds `@State` for sidebar selection (`enum SidebarItem { case inbox, today, logbook, project(Int) }`).
- **Sidebar.swift** — sections + projects list. SF Symbols: `tray.fill` (Inbox), `star.fill` yellow (Today), `archivebox.fill` (Logbook), `circle.dashed` (projects). Match widget aesthetic: cream background `Color(red: 0.98, green: 0.97, blue: 0.94)` in light mode (use system in dark).
- **TaskStore.swift** — `@Observable` ViewModel. Holds `[VikunjaTask]` (all undone) + `[VikunjaTask]` (recent done for Logbook) + `[VikunjaProject]`. Methods: `refresh()`, `complete(id:)`, `reopen(id:)`, optimistic mutation. Background poll every 60s while app is foregrounded. Cache last fetch in `UserDefaults.standard` keyed by `app.cache.tasks` for instant cold start.
- **TaskListView.swift** — takes `tasks: [VikunjaTask]` and `mode: GroupingMode` (`.byDate` for Today, `.byTagFilter` for project, `.byCompletionDate` for Logbook). Renders sections with collapsible headers.
- **TaskRow.swift** — circle checkbox left (16pt, animated to filled checkmark on tap), title (13pt regular), notes preview (11pt secondary, 1 line), tag capsules (10pt). Hover highlight on Mac. Swipe-to-complete on iOS.
- **InboxView / TodayView / LogbookView / ProjectView.swift** — thin wrappers around `TaskListView` with the right filter + grouping.
- **API additions in `VikunjaCore/VikunjaAPI.swift`**:
  - `fetchAllUndoneTasks() -> [VikunjaTask]` (factor out of current `fetchUpcomingTasks`)
  - `fetchDoneTasks(page:) -> [VikunjaTask]` — `?filter=done+%3D+true&sort_by=updated&order_by=desc`
  - Keep `fetchUpcomingTasks` unchanged so widget keeps working.

After Phase 1: app shows real data, completion + undo work, but no editing yet.

## Phase 2 — Quick Add with Swift-native parser
- **VikunjaCore/QuickAddParser.swift** — port from Vikunja's `parseTaskText.ts` (source on github.com/go-vikunja/frontend). Tokens to support:
  - `*tag` → labels
  - `+project` → project (case-insensitive prefix match against known projects; ambiguous → falls back to current view's project)
  - `!1`–`!5` → priority
  - Dates: `today`, `tomorrow`, `tom`, weekday names (`mon`/`monday` = next occurrence), `MMM d` (`apr 30`), `in N days/weeks/months`, `next week`
  - Recurrence: `every day/week/month/year`, `every N days`, `every monday`, `every weekday`
  - Returns `(cleanedTitle: String, dueDate: Date?, repeatAfter: Int?, repeatMode: Int?, priority: Int?, labelTitles: [String], projectName: String?)`
- **QuickAddSheet.swift** — single-line `TextField` + small live-preview row showing parsed chips below ("📅 Tomorrow · *errands · +Home"). ⌘N opens it. Esc cancels. Return submits.
- **Submission flow**:
  1. Resolve project (parsed `+name` or current view's project, fallback to Inbox).
  2. Resolve labels: `GET /labels?s=name`, create with `PUT /labels` if missing.
  3. `PUT /projects/{id}/tasks` with title + structured fields.
  4. Optimistic insert into `TaskStore`, reconcile with server response.
- **Tests**: `QuickAddParserTests.swift` with ~30 cases covering each token + combinations + ambiguous inputs. Add a test target to `project.yml`.

## Phase 3 — Inline editing
- Tap row → expands to inline editor (animated, no modal). Fields:
  - Title (editable)
  - Notes (`description`, multi-line, lazy-loaded via `GET /tasks/{id}` for HTML→plaintext if needed)
  - When picker (Today / Tomorrow / Specific date / No date) — sets `due_date`
  - Deadline picker — sets `end_date`
  - Tags multi-select (existing labels; "+ new" creates one)
  - Project picker
  - Reminder picker (see Phase 4)
- Save on collapse, Esc, or outside tap. Use `POST /tasks/{id}` with diffed fields only.
- Drag handle (Mac) / long-press reorder (iOS) for `position` within a project.

## Phase 4 — Local reminders
- Vikunja stores reminders as ISO timestamps in `task.reminders` array.
- On every refresh: diff incoming reminders vs. previously-scheduled `UNNotificationRequest`s. Schedule new ones, cancel removed ones, leave unchanged ones alone. Use stable identifier `vikunja.reminder.{taskId}.{reminderTimestamp}`.
- Request `UNAuthorizationOptions.alert + .sound` on first app launch (both platforms).
- Tapping a notification deep-links to the task: register `vikunja://task/{id}` URL scheme; handler opens app and navigates `TaskStore` to that task.
- Reminder picker in inline editor: "At due date", "5 min before", "1 hour before", "1 day before", "Custom…".

## Phase 5 — Polish & ship
- Search: ⌘F opens overlay, client-side filter across loaded tasks.
- Drag-drop between sidebar items: dropping a task on a project reassigns; on Today sets due=today.
- Completion animation: row dims + strikethrough + 4s undo bar (reuse widget's `SharedState` pattern but in-process).
- Empty states ("Nothing for today 🌤" — only emoji if you want it; otherwise icon).
- App icon: reuse existing widget icon for v2.
- Bump `MARKETING_VERSION` to `2.0` in `project.yml` for both app targets. Archive each, upload to App Store Connect, install via TestFlight.

---

## Things explicitly NOT in scope
- Someday / Anytime sidebar items
- Areas / project grouping
- Subtasks / checklists
- Sharing / collaboration
- Calendar integration
- Web/Watch/Vision targets

## Files Sonnet will create or move
**Move:** `VikunjaModels.swift`, `VikunjaAPI.swift`, `VikunjaConfig.swift`, `SharedState.swift` → `VikunjaCore/`
**New in `VikunjaCore/`:** `QuickAddParser.swift`, `QuickAddParserTests.swift`
**New in `VikunjaWidgetApp/`:** `AppRoot.swift`, `Sidebar.swift`, `TaskStore.swift`, `TaskListView.swift`, `TaskRow.swift`, `QuickAddSheet.swift`, `InlineTaskEditor.swift`, `ReminderScheduler.swift`, plus thin `InboxView.swift` / `TodayView.swift` / `LogbookView.swift` / `ProjectView.swift`
**Modified:** `project.yml`, `ContentView.swift` (deleted), `VikunjaAPI.swift` (new fetch methods)

## Gotchas to carry over
- Use `make gen`, never `xcodegen generate` directly
- macOS app needs `com.apple.security.network.client` entitlement — already set for the widget but verify for the app target
- Vikunja due dates are midnight UTC; render in local time
- `/tasks/all` is broken — keep using per-project fetch
- Don't add a second `info:` block for any iOS target
