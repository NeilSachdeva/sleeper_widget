import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity: a scoreboard on the Lock Screen (near notifications) and in
/// the Dynamic Island while your fantasy matchup is being played.
struct MatchupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchupActivityAttributes.self) { context in
            LockScreenMatchupView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(AppConfig.matchupDeepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedTeamView(
                        name: context.attributes.myTeamName,
                        avatarId: context.attributes.myAvatarId,
                        points: context.state.myPoints,
                        record: context.state.myRecord,
                        isLeading: context.state.margin >= 0,
                        alignment: .leading
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTeamView(
                        name: context.attributes.opponentTeamName,
                        avatarId: context.attributes.opponentAvatarId,
                        points: context.state.opponentPoints,
                        record: context.state.opponentRecord,
                        isLeading: context.state.margin <= 0,
                        alignment: .trailing
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("WEEK \(context.attributes.week)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        PhaseBadge(phase: context.state.phase, compact: true)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.attributes.leagueName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(context.state.marginText)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(WidgetStyle.marginColor(margin: context.state.margin))
                        RefreshButton()
                    }
                }
            } compactLeading: {
                ScoreText(points: context.state.myPoints, size: 14, weight: .bold)
                    .foregroundStyle(context.state.margin >= 0 ? WidgetStyle.winning : Color.white)
                    .padding(.leading, 4)
            } compactTrailing: {
                ScoreText(points: context.state.opponentPoints, size: 14, weight: .semibold)
                    .foregroundStyle(context.state.margin < 0 ? WidgetStyle.losing : WidgetStyle.dimmed)
                    .padding(.trailing, 4)
            } minimal: {
                Text(context.state.isTied ? "=" : (context.state.margin > 0 ? "+" : "−") + ScoreFormat.points(abs(context.state.margin)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(WidgetStyle.marginColor(margin: context.state.margin))
            }
            .widgetURL(AppConfig.matchupDeepLink)
            .keylineTint(WidgetStyle.marginColor(margin: context.state.margin))
        }
    }
}

// MARK: - Lock Screen banner

struct LockScreenMatchupView: View {
    let attributes: MatchupActivityAttributes
    let state: MatchupActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TeamRow(
                    name: attributes.myTeamName,
                    avatarId: attributes.myAvatarId,
                    record: state.myRecord,
                    points: state.myPoints,
                    isLeading: state.margin >= 0,
                    alignment: .leading
                )
                VStack(spacing: 3) {
                    Text("WK \(attributes.week)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    PhaseBadge(phase: state.phase, compact: true)
                    Text(state.marginText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetStyle.marginColor(margin: state.margin))
                }
                .frame(minWidth: 52)
                TeamRow(
                    name: attributes.opponentTeamName,
                    avatarId: attributes.opponentAvatarId,
                    record: state.opponentRecord,
                    points: state.opponentPoints,
                    isLeading: state.margin <= 0,
                    alignment: .trailing
                )
            }
            HStack(spacing: 8) {
                Text(attributes.leagueName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isStale {
                    Text("Scores may be out of date")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    UpdatedText(date: state.updatedAt)
                }
                RefreshButton()
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Runs `RefreshMatchupIntent` in the app's process without opening the app.
/// Interactive controls are only honoured in the Lock Screen and expanded presentations.
private struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshMatchupIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .bold))
                .padding(6)
                .background(.white.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh scores")
    }
}

private struct TeamRow: View {
    let name: String
    let avatarId: String?
    let record: String?
    let points: Double
    let isLeading: Bool
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 8) {
            if alignment == .leading {
                AvatarView(avatarId: avatarId, name: name, size: 34)
            }
            VStack(alignment: alignment, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let record {
                    Text(record)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                ScoreText(points: points, size: 24, weight: isLeading ? .heavy : .semibold)
                    .foregroundStyle(isLeading ? Color.white : Color.white.opacity(0.7))
            }
            if alignment == .trailing {
                AvatarView(avatarId: avatarId, name: name, size: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

// MARK: - Dynamic Island expanded

private struct ExpandedTeamView: View {
    let name: String
    let avatarId: String?
    let points: Double
    let record: String?
    let isLeading: Bool
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                if alignment == .leading {
                    AvatarView(avatarId: avatarId, name: name, size: 22)
                }
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if alignment == .trailing {
                    AvatarView(avatarId: avatarId, name: name, size: 22)
                }
            }
            ScoreText(points: points, size: 22, weight: isLeading ? .heavy : .semibold)
                .foregroundStyle(isLeading ? Color.white : WidgetStyle.dimmed)
            if let record {
                Text(record)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .padding(.horizontal, 4)
    }
}

// MARK: - Previews

#Preview("Lock Screen", as: .content, using: MatchupActivityAttributes.preview) {
    MatchupLiveActivity()
} contentStates: {
    MatchupActivityAttributes.ContentState.previewLive
    MatchupActivityAttributes.ContentState.previewTrailing
    MatchupActivityAttributes.ContentState.previewFinal
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: MatchupActivityAttributes.preview) {
    MatchupLiveActivity()
} contentStates: {
    MatchupActivityAttributes.ContentState.previewLive
}

#Preview("Island Compact", as: .dynamicIsland(.compact), using: MatchupActivityAttributes.preview) {
    MatchupLiveActivity()
} contentStates: {
    MatchupActivityAttributes.ContentState.previewTrailing
}
