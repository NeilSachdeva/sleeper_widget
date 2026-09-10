import SwiftUI

struct MatchupView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let snapshot = model.snapshot {
                    ScoreboardCard(snapshot: snapshot)
                    LiveActivityCard(snapshot: snapshot)
                } else if model.isBusy {
                    ProgressView("Loading your matchup…")
                        .padding(.top, 60)
                } else {
                    ContentUnavailableView {
                        Label("No matchup yet", systemImage: "football")
                    } description: {
                        Text(model.errorMessage ?? "Pull to refresh once the season is underway.")
                    } actions: {
                        Button("Refresh") { Task { await model.refresh(force: true) } }
                    }
                    .padding(.top, 40)
                }

                if let error = model.errorMessage, model.snapshot != nil {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                if let lastRefresh = model.lastRefresh {
                    HStack(spacing: 4) {
                        Text("Updated")
                        Text(lastRefresh, style: .relative)
                        Text("ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .refreshable { await model.refresh(force: true) }
        .navigationTitle(model.leagueName ?? "Matchup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await model.handleForeground()
        }
        .onDisappear {
            model.stopPolling()
        }
    }
}

// MARK: - Scoreboard

private struct ScoreboardCard: View {
    let snapshot: MatchupSnapshot

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Week \(snapshot.week)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                phaseLabel
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                TeamColumn(team: snapshot.me, leading: snapshot.margin >= 0)
                if !snapshot.isBye {
                    VStack(spacing: 4) {
                        Text("VS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                        Text(snapshot.marginText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(marginColor)
                    }
                    .padding(.top, 36)
                }
                if let opponent = snapshot.opponent {
                    TeamColumn(team: opponent, leading: snapshot.margin < 0)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "bed.double.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Bye week")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var marginColor: Color {
        if snapshot.margin > 0 { return .green }
        if snapshot.margin < 0 { return .red }
        return .secondary
    }

    @ViewBuilder
    private var phaseLabel: some View {
        HStack(spacing: 5) {
            if snapshot.phase == .live {
                Circle().fill(.red).frame(width: 7, height: 7)
            }
            Text(snapshot.phase.label)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(snapshot.phase == .live ? Color.red : Color.secondary)
    }
}

private struct TeamColumn: View {
    let team: MatchupSnapshot.Team
    let leading: Bool

    var body: some View {
        VStack(spacing: 6) {
            AvatarView(avatarId: team.avatarId, name: team.name, size: 56)
            Text(team.name)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let owner = team.ownerName {
                Text("@\(owner)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(ScoreFormat.points(team.points))
                .font(.system(size: 34, weight: leading ? .heavy : .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(leading ? Color.primary : Color.secondary)
            if let record = team.record {
                Text(record)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live Activity controls

private struct LiveActivityCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: MatchupSnapshot

    private var window: GameWindow.Window? { GameWindow.current(week: snapshot.week) }
    private var nextWindow: GameWindow.Window? { GameWindow.next(week: snapshot.week) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Activity", systemImage: "bolt.badge.clock")
                    .font(.headline)
                Spacer()
                if model.isLiveActivityRunning {
                    Text("On")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !model.liveActivity.areActivitiesEnabled {
                Text("Live Activities are off for this app. Turn them on in Settings › \(AppConfig.displayName) › Live Activities.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                if model.isLiveActivityRunning {
                    Button("Stop", role: .destructive) {
                        Task { await model.stopLiveActivity() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await model.startLiveActivity() }
                    } label: {
                        Label("Show on Lock Screen", systemImage: "lock.iphone")
                    }
                    .buttonStyle(.borderedProminent)
                    // Final weeks have nothing left to track; the next refresh would end it anyway.
                    .disabled(snapshot.isBye || snapshot.phase == .final || !model.liveActivity.areActivitiesEnabled)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var statusText: String {
        if model.isLiveActivityRunning {
            return "Scores update on the Lock Screen and in the Dynamic Island. Pull to refresh for the latest."
        }
        if snapshot.isBye {
            return "You're on a bye this week, so there's nothing to track."
        }
        let autoStart = SharedStore.autoStartLiveActivity
        if let window {
            return autoStart
                ? "\(window.label) games are on. The Live Activity starts automatically when you open the app during games."
                : "\(window.label) games are on. Auto-start is off in Settings, so pin the matchup here when you want it."
        }
        if let nextWindow {
            let formatter = DateFormatter()
            formatter.timeZone = .current
            formatter.dateFormat = "EEE h:mm a"
            let tail = autoStart
                ? "You can pin the matchup now, or it will appear automatically when you open the app during games."
                : "You can pin the matchup now; auto-start is off in Settings."
            return "Next games: \(nextWindow.label), \(formatter.string(from: nextWindow.start)). \(tail)"
        }
        return "Pin your matchup to the Lock Screen any time."
    }
}
