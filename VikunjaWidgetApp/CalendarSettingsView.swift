//
//  CalendarSettingsView.swift
//  VikunjaWidgetApp
//
//  The calendar section of Settings. Ported from Calvane's `WidgetSettingsView`, but
//  **not** a straight lift: Calvane's was a standalone `List` with `Section`s, and
//  Veyrn's Settings is a `ScrollView` of headline-plus-controls blocks. The compact
//  calendar chooser (colour dot · title · source · check) is the part that carried
//  over as-is.
//
//  Shape of the section, and why:
//
//      Show Calendar Events        ← always visible, default off
//      └─ everything else          ← only once access is granted
//
//  The sub-controls stay hidden until there's access so the section is never a wall
//  of dead switches, and so the only thing a user sees before opting in is the one
//  switch that explains what opting in does.
//

import SwiftUI
import WidgetKit

struct CalendarSettingsView: View {
    // Bound to the App Group store, not `UserDefaults.standard` — see
    // `CalendarPreferences.store` for why there is deliberately only one copy.
    @AppStorage(CalendarPreferences.enabledKey, store: CalendarPreferences.store)
    private var calendarEnabled: Bool = false
    @State private var model = CalendarAccessModel()

    private var selectedCount: Int {
        model.calendars.filter { model.selection.includes($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar")
                .font(.headline)

            Toggle("Show Calendar Events", isOn: $calendarEnabled)
                .onChange(of: calendarEnabled) { _, on in
                    // The binding has already written to the App Group, which is what
                    // the widget reads — so this only has to nudge it and reload.
                    WidgetCenter.shared.reloadTimelines(ofKind: VeyrnCalendarWidgetKind)
                    Task {
                        if on { await model.requestAccessAndLoad() } else { await model.load() }
                    }
                }

            Text("Shows your calendar events alongside tasks in Scheduled, and adds a calendar widget. Events are read-only and never leave your device.")
                .font(.caption).foregroundStyle(.secondary)

            if calendarEnabled {
                switch model.authorization {
                case .fullAccess:
                    grantedControls
                case .notDetermined:
                    Button("Grant Calendar Access") {
                        Task { await model.requestAccessAndLoad() }
                    }
                    .buttonStyle(.bordered)
                case .denied, .restricted, .writeOnly:
                    deniedNotice
                }
            }
        }
        .task { await model.load() }
    }

    // MARK: - Access denied

    private var deniedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Veyrn doesn't have permission to read your calendar.")
                .font(.caption).foregroundStyle(.secondary)
            #if os(macOS)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            #else
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            #endif
        }
    }

    // MARK: - Granted

    @ViewBuilder
    private var grantedControls: some View {
        Stepper(
            "Days ahead: \(model.options.daysAhead)",
            value: Binding(
                get: { model.options.daysAhead },
                set: { newValue in model.updateOptions { $0.daysAhead = newValue } }
            ),
            in: WidgetOptions.daysAheadRange
        )

        Toggle("Show all-day events", isOn: Binding(
            get: { model.options.showAllDay },
            set: { newValue in model.updateOptions { $0.showAllDay = newValue } }
        ))

        Toggle("Show declined events", isOn: Binding(
            get: { model.options.showDeclined },
            set: { newValue in model.updateOptions { $0.showDeclined = newValue } }
        ))

        if let loadError = model.loadError {
            Text(loadError)
                .font(.caption).foregroundStyle(.red)
        }

        HStack {
            Text("Calendars")
                .font(.subheadline).fontWeight(.medium)
            Spacer()
            Button(model.selection.isAll ? "Hide All" : "Show All") {
                model.setAll(!model.selection.isAll)
            }
            .font(.caption)
        }
        .padding(.top, 4)

        ForEach(model.calendars) { cal in
            let on = model.selection.includes(cal)
            Button {
                model.setIncluded(cal, !on)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(cgColor: cal.color.cgColor))
                        .frame(width: 12, height: 12)
                    Text(cal.title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(cal.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .imageScale(.large)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        // `CalendarSelection.all` is sticky on purpose: a new calendar added later is
        // included automatically rather than silently missing from the widget.
        Text(model.selection.isAll
             ? "Showing all calendars. New calendars appear automatically."
             : "Showing \(selectedCount) of \(model.calendars.count) calendars.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
