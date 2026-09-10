import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var autoStart = SharedStore.autoStartLiveActivity
    @State private var relayURLText = SharedStore.relayURL?.absoluteString ?? ""
    @State private var relayTokenText = SharedStore.relayAuthToken ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Sleeper user", value: model.user?.displayName ?? model.user?.username ?? "—")
                    LabeledContent("League", value: model.leagueName ?? "—")
                    Button("Change league") {
                        model.changeLeague()
                        dismiss()
                    }
                } header: {
                    Text("Account")
                }

                Section {
                    Toggle("Start automatically during games", isOn: $autoStart)
                        .onChange(of: autoStart) { _, value in
                            SharedStore.autoStartLiveActivity = value
                        }
                    LabeledContent("Live Activities", value: model.liveActivity.areActivitiesEnabled ? "Enabled" : "Off in Settings")
                    LabeledContent("Frequent updates", value: model.liveActivity.frequentPushesEnabled ? "Allowed" : "Off in Settings")
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("When on, opening the app during NFL game windows pins your matchup to the Lock Screen. iOS keeps a Live Activity for up to 8 hours; scores refresh when you open the app, in the background when iOS allows, and continuously if a push relay is configured.")
                }

                Section {
                    TextField("https://your-relay.example.com", text: $relayURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.updateRelaySettings(url: relayURLText, token: relayTokenText) } }
                    SecureField("Relay token (optional)", text: $relayTokenText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save relay settings") {
                        Task { await model.updateRelaySettings(url: relayURLText, token: relayTokenText) }
                    }
                    if let status = model.liveActivity.relayStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(status.hasPrefix("Relay error") ? Color.red : Color.secondary)
                    }
                } header: {
                    Text("Push relay (optional)")
                } footer: {
                    Text("Run the server in the repo's server/ folder to start and update the Live Activity from the cloud, even when the app is closed. Leave blank to rely on foreground and background refresh. The token matches the relay's RELAY_AUTH_TOKEN, if you set one.")
                }

                Section {
                    LabeledContent("App Group", value: SharedStore.isAppGroupAvailable ? "OK" : "Missing")
                    tokenRow(title: "Push-to-start token", value: model.liveActivity.pushToStartToken)
                    tokenRow(title: "Activity token", value: model.liveActivity.activityPushToken)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Tokens are registered with the relay automatically. Tap to copy.")
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        model.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func tokenRow(title: String, value: String?) -> some View {
        if let value {
            Button {
                UIPasteboard.general.string = value
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(value)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            LabeledContent(title, value: "Not issued yet")
        }
    }
}
