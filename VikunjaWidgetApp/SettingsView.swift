import SwiftUI
import WidgetKit

struct SettingsView: View {
    var onSave: (() -> Void)? = nil

    @State private var host = ""
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss

    private var defaults: UserDefaults? { UserDefaults(suiteName: VikunjaConfig.appGroupSuite) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(VikunjaConfig.isConfigured ? "Settings" : "Welcome to Vikunja")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Enter your Vikunja instance URL and an API token.")
                    .foregroundStyle(.secondary)
            }

            // Host
            VStack(alignment: .leading, spacing: 6) {
                Text("Instance URL")
                    .font(.headline)
                TextField("https://tasks.example.com", text: $host)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Text("Your Vikunja server — without /api/v1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Token
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if VikunjaConfig.isConfigured {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(VikunjaConfig.isConfigured ? "Save" : "Get Started") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty ||
                          token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(32)
        .onAppear { loadSaved() }
    }

    // MARK: - Persistence

    private func loadSaved() {
        host = defaults?.string(forKey: "vikunja_host") ?? ""
        token = defaults?.string(forKey: "vikunja_api_token") ?? ""
    }

    private func save() {
        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults?.set(trimmedHost, forKey: "vikunja_host")
        defaults?.set(trimmedToken, forKey: "vikunja_api_token")

        host = trimmedHost
        token = trimmedToken

        WidgetCenter.shared.reloadAllTimelines()
        onSave?()
        dismiss()
    }
}
