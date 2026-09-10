import SwiftUI

struct LeaguePickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.leagues.isEmpty && !model.isBusy {
                ContentUnavailableView {
                    Label("No leagues found", systemImage: "person.3")
                } description: {
                    Text("This Sleeper account has no NFL leagues for the current season.")
                } actions: {
                    Button("Try again") { Task { await model.loadLeagues() } }
                }
            } else {
                Section {
                    ForEach(model.leagues) { league in
                        Button {
                            Task { await model.select(league: league) }
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: SleeperAPI.avatarThumbnailURL(for: league.avatar)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "trophy.fill").foregroundStyle(.secondary)
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(league.name).foregroundStyle(.primary)
                                    Text("\(league.season) · \(league.totalRosters ?? 0) teams")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Choose a league")
                } footer: {
                    Text("You can switch leagues later from Settings.")
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(model.user?.displayName ?? "Leagues")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isBusy {
                    ProgressView()
                } else {
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
            }
        }
        .task {
            if model.leagues.isEmpty { await model.loadLeagues() }
        }
    }
}
