import SwiftUI

/// Small shared pieces for the Live Activity and widget views.
enum WidgetStyle {
    // Every surface these are drawn on is dark (tinted Lock Screen banner, Dynamic
    // Island, dark widget gradient), so use explicit colors rather than semantic ones
    // that flip to dark gray in Light Mode.
    static let winning = Color.green
    static let losing = Color.red
    static let neutral = Color.white.opacity(0.75)
    static let dimmed = Color.white.opacity(0.7)

    static func marginColor(margin: Double) -> Color {
        if margin > 0 { return winning }
        if margin < 0 { return losing }
        return neutral
    }
}

/// "LIVE" / "FINAL" / "UPCOMING" pill.
struct PhaseBadge: View {
    let phase: MatchupPhase
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if phase == .live {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
            Text(phase.label.uppercased())
                .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
                .tracking(0.5)
        }
        .foregroundStyle(phase == .live ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
    }
}

/// Fantasy score with tabular digits so it doesn't jitter between updates.
struct ScoreText: View {
    let points: Double
    var size: CGFloat = 28
    var weight: Font.Weight = .bold

    var body: some View {
        Text(ScoreFormat.points(points))
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Relative "2 min ago" text that the system keeps current without new updates.
struct UpdatedText: View {
    let date: Date

    var body: some View {
        HStack(spacing: 3) {
            Text("Updated")
            Text(date, style: .relative)
            Text("ago")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
