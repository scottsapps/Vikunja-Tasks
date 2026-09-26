//
//  CalendarSettingsView.swift
//  VikunjaWidgetApp
//
//  The Calendar pane of Settings. Ported from Calvane's `WidgetSettingsView` — the
//  compact calendar chooser (colour dot · title · source · check) carried over intact;
//  the rest was re-laid-out for Veyrn.
//
//  Two switches, deliberately separate:
//
//      Show Calendar in Veyrn        ← master. Grants access; powers the widget.
//      └─ Show in Scheduled   ← only the task list. Opt-out, default on.
//
//  Wanting the calendar widget is not the same as wanting events interleaved into
//  your task list, and turning the feature on for the widget should not silently
//  rearrange the Scheduled view. The widget reads only the master switch.
//
//  Everything below the master switch stays hidden until access is granted, so the
//  pane is never a wall of dead controls, and the only thing visible before opting in
//  is the one switch that explains what opting in does.
//

import SwiftUI
import WidgetKit

struct CalendarSettingsView: View {
    // Both bound to the App Group store, not `UserDefaults.standard` — see
    // `CalendarPreferences.store` for why there is deliberately only one copy.
    @AppStorage(CalendarPreferences.enabledKey, store: CalendarPreferences.store)
    private var calendarEnabled: Bool = false

    @AppStorage(CalendarPreferences.showInScheduledKey, store: CalendarPreferences.store)
    private var showInScheduled: Bool = true

    @State private var model = CalendarAccessModel()
    /// Once per presentation.
    @State private var didSignalView = false

    private var selectedCount: Int {
        model.calendars.filter { model.selection.includes($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show Calendar in Veyrn", isOn: $calendarEnabled)
                .onChange(of: calendarEnabled) { _, on in
                    // The binding has already written to the App Group, which is what
                    // the widget reads — so this only has to nudge it and reload.
                    WidgetCenter.shared.reloadTimelines(ofKind: VeyrnCalendarWidgetKind)
                    Task {
                        if on { await model.requestAccessAndLoad() } else { await model.load() }
                    }
                }

            Text("Lets Veyrn read the calendars on this device, for the Veyrn Calendar widget. Events are read-only and never leave your device.")
                .font(.caption).foregroundStyle(.secondary)

            if calendarEnabled {
                switch model.authorization {
                case .fullAccess:
                    grantedControls
                case .notDetermined:
                    Button("Continue") {
                        Task { await model.requestAccessAndLoad() }
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                case .denied, .restricted, .writeOnly:
                    deniedNotice
                }
            }
        }
        .task {
            if !didSignalView {
                didSignalView = true
                VeyrnTelemetry.signal("Calendar.settingsViewed")
            }
            await model.load()
        }
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
        .padding(.top, 4)
    }

    // MARK: - Granted

    @ViewBuilder
    private var grantedControls: some View {
        Divider().padding(.vertical, 6)

        Toggle("Show in Scheduled", isOn: $showInScheduled)
            .onChange(of: showInScheduled) { _, _ in
                // Only the in-app list cares; the widget is unaffected either way.
                // `TodayView` reloads on scene-active, which covers dismissing Settings.
            }
        Text("Also show events alongside tasks in the Scheduled list. Turn this off to keep the calendar for the widget only.")
            .font(.caption).foregroundStyle(.secondary)

        Divider().padding(.vertical, 6)

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
        .padding(.top, 10)

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

/// Whether the calendar feature is on, for the Settings root row's trailing label.
enum CalendarSettingsSummary {
    static var current: LocalizedStringKey {
        guard CalendarPreferences.isEnabled else { return "Off" }
        guard EventKitSource.authorization.canRead else { return "Needs access" }
        return CalendarPreferences.showsInScheduled ? "On" : "Widget only"
    }
}
