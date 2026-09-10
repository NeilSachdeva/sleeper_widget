import SwiftUI
import WidgetKit

// MARK: - Timeline

struct MatchupEntry: TimelineEntry {
    let date: Date
    let snapshot: MatchupSnapshot?
    let isConfigured: Bool
}

struct MatchupProvider: TimelineProvider {
    func placeholder(in context: Context) -> MatchupEntry {
        MatchupEntry(date: Date(), snapshot: .preview, isConfigured: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MatchupEntry) -> Void) {
        if context.isPreview {
            completion(MatchupEntry(date: Date(), snapshot: .preview, isConfigured: true))
        } else {
            completion(Self.storedEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MatchupEntry>) -> Void) {
        Task {
            let entry = await Self.freshEntry()
            let policy: TimelineReloadPolicy = .after(Self.nextRefresh(after: entry.date, snapshot: entry.snapshot))
            completion(Timeline(entries: [entry], policy: policy))
        }
    }

    /// Whatever the app last saved, without touching the network.
    static func storedEntry() -> MatchupEntry {
        MatchupEntry(date: Date(), snapshot: SharedStore.snapshot, isConfigured: SharedStore.isConfigured)
    }

    /// Snapshots newer than this are served as-is; the app writes one on every poll.
    static let reuseInterval: TimeInterval = 2 * 60

    /// Fetches live scores when the widget is refreshed; reuses a just-written snapshot
    /// and falls back to the stored one when offline.
    static func freshEntry(now: Date = Date()) async -> MatchupEntry {
        guard let userId = SharedStore.userId, let leagueId = SharedStore.leagueId else {
            return MatchupEntry(date: now, snapshot: nil, isConfigured: false)
        }
        if let stored = SharedStore.snapshot, now.timeIntervalSince(stored.updatedAt) < reuseInterval {
            return MatchupEntry(date: now, snapshot: stored, isConfigured: true)
        }
        if let fresh = try? await MatchupService().fetchSnapshot(userId: userId, leagueId: leagueId) {
            SharedStore.snapshot = fresh
            SharedStore.lastRefresh = fresh.updatedAt
            return MatchupEntry(date: fresh.updatedAt, snapshot: fresh, isConfigured: true)
        }
        return storedEntry()
    }

    /// Refresh often while games are on; otherwise wake at the next kickoff, checking in
    /// every few hours so a new week's matchup still shows up.
    static func nextRefresh(after date: Date, snapshot: MatchupSnapshot?) -> Date {
        let week = snapshot?.week ?? 1
        if GameWindow.current(at: date, week: week) != nil {
            return date.addingTimeInterval(15 * 60)
        }
        let fallback = date.addingTimeInterval(4 * 3600)
        if let next = GameWindow.next(after: date, week: week) {
            return min(next.start, fallback)
        }
        return fallback
    }
}

// MARK: - Widget

/// Lock Screen (accessory) and Home Screen views of the current matchup.
struct MatchupWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.matchupWidgetKind, provider: MatchupProvider()) { entry in
            MatchupWidgetView(entry: entry)
        }
        .configurationDisplayName("Fantasy Matchup")
        .description("Your Sleeper matchup score at a glance.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCircular,
            .systemSmall,
            .systemMedium,
        ])
    }
}

struct MatchupWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MatchupEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryInline:
                    InlineMatchupView(snapshot: snapshot)
                case .accessoryCircular:
                    CircularMatchupView(snapshot: snapshot)
                case .accessoryRectangular:
                    RectangularMatchupView(snapshot: snapshot)
                default:
                    HomeScreenMatchupView(snapshot: snapshot, family: family)
                }
            } else {
                EmptyMatchupView(isConfigured: entry.isConfigured, family: family)
            }
        }
        .widgetURL(AppConfig.matchupDeepLink)
        .containerBackground(for: .widget) {
            switch family {
            case .accessoryCircular, .accessoryRectangular, .accessoryInline:
                Color.clear
            default:
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.11, green: 0.15, blue: 0.27)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

// MARK: - Accessory families

private struct InlineMatchupView: View {
    let snapshot: MatchupSnapshot

    var body: some View {
        if let opponent = snapshot.opponent {
            Text("\(Image(systemName: "football.fill")) \(ScoreFormat.points(snapshot.me.points))–\(ScoreFormat.points(opponent.points)) · \(snapshot.marginText)")
        } else {
            Text("\(Image(systemName: "football.fill")) Bye week")
        }
    }
}

private struct CircularMatchupView: View {
    let snapshot: MatchupSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                Text(ScoreFormat.compactPoints(snapshot.me.points))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Rectangle()
                    .frame(width: 24, height: 1)
                    .opacity(0.5)
                Text(snapshot.opponent.map { ScoreFormat.compactPoints($0.points) } ?? "BYE")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .widgetAccentable()
        }
    }
}

private struct RectangularMatchupView: View {
    let snapshot: MatchupSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "football.fill")
                Text("Week \(snapshot.week)")
                    .fontWeight(.semibold)
                Text("·")
                Text(snapshot.phase.label)
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .widgetAccentable()
            scoreLine(team: snapshot.me, bold: snapshot.margin >= 0)
            if let opponent = snapshot.opponent {
                scoreLine(team: opponent, bold: snapshot.margin < 0)
            } else {
                Text("Bye week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreLine(team: MatchupSnapshot.Team, bold: Bool) -> some View {
        HStack(spacing: 4) {
            Text(team.name)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(ScoreFormat.points(team.points))
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: bold ? .bold : .regular, design: .rounded))
    }
}

// MARK: - Home Screen families

private struct HomeScreenMatchupView: View {
    let snapshot: MatchupSnapshot
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.leagueName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                PhaseBadge(phase: snapshot.phase, compact: true)
            }
            if family == .systemMedium {
                HStack(spacing: 12) {
                    teamColumn(snapshot.me, leading: snapshot.margin >= 0, alignment: .leading)
                    VStack(spacing: 2) {
                        Text("WK \(snapshot.week)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(snapshot.marginText)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(WidgetStyle.marginColor(margin: snapshot.margin))
                    }
                    if let opponent = snapshot.opponent {
                        teamColumn(opponent, leading: snapshot.margin < 0, alignment: .trailing)
                    } else {
                        Text("Bye week")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    smallRow(snapshot.me, leading: snapshot.margin >= 0)
                    if let opponent = snapshot.opponent {
                        smallRow(opponent, leading: snapshot.margin < 0)
                    } else {
                        Text("Bye week")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text("Week \(snapshot.week)")
                    Spacer()
                    Text(snapshot.marginText)
                        .fontWeight(.bold)
                        .foregroundStyle(WidgetStyle.marginColor(margin: snapshot.margin))
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
    }

    private func teamColumn(_ team: MatchupSnapshot.Team, leading: Bool, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            AvatarView(avatarId: team.avatarId, name: team.name, size: 30)
            Text(team.name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ScoreText(points: team.points, size: 24, weight: leading ? .heavy : .semibold)
                .foregroundStyle(leading ? Color.white : Color.white.opacity(0.7))
            if let record = team.record {
                Text(record)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func smallRow(_ team: MatchupSnapshot.Team, leading: Bool) -> some View {
        HStack(spacing: 6) {
            AvatarView(avatarId: team.avatarId, name: team.name, size: 20)
            Text(team.name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            ScoreText(points: team.points, size: 16, weight: leading ? .heavy : .semibold)
                .foregroundStyle(leading ? Color.white : Color.white.opacity(0.7))
        }
    }
}

// MARK: - Empty states

private struct EmptyMatchupView: View {
    let isConfigured: Bool
    let family: WidgetFamily

    private var message: String {
        if isConfigured { return "Open the app to load your matchup" }
        return SharedStore.userId == nil ? "Open the app to sign in to Sleeper" : "Open the app to choose a league"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(Image(systemName: "football.fill")) \(AppConfig.displayName)")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "football.fill")
                    .font(.title3)
                    .widgetAccentable()
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Fantasy Matchup", systemImage: "football.fill")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .widgetAccentable()
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "football.fill")
                    .font(.title2)
                Text(message)
                    .font(.footnote)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Previews

#Preview("Rectangular", as: .accessoryRectangular) {
    MatchupWidget()
} timeline: {
    MatchupEntry(date: Date(), snapshot: .preview, isConfigured: true)
    MatchupEntry(date: Date(), snapshot: .previewBye, isConfigured: true)
    MatchupEntry(date: Date(), snapshot: nil, isConfigured: false)
}

#Preview("Circular", as: .accessoryCircular) {
    MatchupWidget()
} timeline: {
    MatchupEntry(date: Date(), snapshot: .preview, isConfigured: true)
}

#Preview("Inline", as: .accessoryInline) {
    MatchupWidget()
} timeline: {
    MatchupEntry(date: Date(), snapshot: .preview, isConfigured: true)
}

#Preview("Medium", as: .systemMedium) {
    MatchupWidget()
} timeline: {
    MatchupEntry(date: Date(), snapshot: .preview, isConfigured: true)
}
