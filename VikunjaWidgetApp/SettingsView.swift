import SwiftUI
import WidgetKit

struct SettingsView: View {
    var onSave: (() -> Void)? = nil

    private enum ServerKind { case cloud, custom }

    @State private var serverKind: ServerKind = .custom
    @State private var host = ""
    @State private var token = ""

    @Environment(\.dismiss) private var dismiss
    @AppStorage("vikunja_font_size_offset") private var fontSizeOffset: Int = 0
    @AppStorage("vikunja_telemetry_opt_in") private var telemetryOptIn: Bool = true

    #if os(macOS)
    @State private var hotkeyKeyCode: UInt32 = VikunjaConfig.quickAddKeyCode
    @State private var hotkeyModifiers: UInt32 = VikunjaConfig.quickAddModifiers
    #endif

    private var defaults: UserDefaults? { UserDefaults(suiteName: VikunjaConfig.appGroupSuite) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(VikunjaConfig.isConfigured ? "Settings" : "Welcome to Veyrn")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Connect to your Vikunja instance.")
                    .foregroundStyle(.secondary)
            }

            // Server picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Server")
                    .font(.headline)
                Picker("Server", selection: $serverKind) {
                    Text("Custom server").tag(ServerKind.custom)
                    Text("Vikunja Cloud").tag(ServerKind.cloud)
                }
                .pickerStyle(.segmented)
                .onChange(of: serverKind) { _, kind in
                    if kind == .cloud { host = VikunjaConfig.vikunjaCloudHost }
                }

                if serverKind == .custom {
                    TextField("https://tasks.example.com", text: $host)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Text("Your Vikunja server — without /api/v1")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // API token
            VStack(alignment: .leading, spacing: 6) {
                Text("API Token")
                    .font(.headline)
                SecureField("tk_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                Text("Vikunja → Profile → Settings → API Tokens")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Recommended: set a long expiration (1 year or more) and grant all permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Font size
            VStack(alignment: .leading, spacing: 6) {
                Text("Task Font Size")
                    .font(.headline)
                Picker("Font Size", selection: $fontSizeOffset) {
                    Text("Small").tag(-1)
                    Text("Medium").tag(0)
                    Text("Large").tag(2)
                    Text("Extra Large").tag(4)
                }
                .pickerStyle(.segmented)
            }

            // Analytics opt-in
            Toggle("Share anonymous usage analytics", isOn: $telemetryOptIn)
                .onChange(of: telemetryOptIn) { _, v in
                    UserDefaults.standard.set(v, forKey: "vikunja_telemetry_opt_in")
                }

            #if os(macOS)
            // Quick Add Shortcut
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Add Shortcut")
                    .font(.headline)
                HotkeyRecorderView(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers)
                    .onChange(of: hotkeyKeyCode) { _, _ in saveHotkey() }
                    .onChange(of: hotkeyModifiers) { _, _ in saveHotkey() }
                Text("Click to record a new global shortcut (default: ⌃Space)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif

            Spacer()

            HStack {
                if VikunjaConfig.isConfigured {
                    Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                }
                Spacer()
                Button(VikunjaConfig.isConfigured ? "Save" : "Get Started") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(32)
        .onAppear { loadSaved() }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults?.set(trimmedHost, forKey: "vikunja_host")
        VikunjaConfig.saveToken(trimmedToken)

        host = trimmedHost
        token = trimmedToken

        VeyrnTelemetry.signal("SignedIn", parameters: [
            "serverKind": serverKind == .cloud ? "cloud" : "custom",
        ])

        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        WatchSessionProvider.shared.syncConfig()
        #endif
        onSave?()
        dismiss()
    }

    private func loadSaved() {
        host = defaults?.string(forKey: "vikunja_host") ?? ""
        token = defaults?.string(forKey: "vikunja_api_token") ?? ""
        serverKind = host == VikunjaConfig.vikunjaCloudHost ? .cloud : .custom
    }

    #if os(macOS)
    private func saveHotkey() {
        VikunjaConfig.quickAddKeyCode = hotkeyKeyCode
        VikunjaConfig.quickAddModifiers = hotkeyModifiers
        NotificationCenter.default.post(name: .vikunjaHotkeyChanged, object: nil)
    }
    #endif
}
