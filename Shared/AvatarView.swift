import SwiftUI

/// Team avatar from the App Group cache, falling back to the team's initials.
/// Works in the app, in widgets, and inside a Live Activity (no network needed).
struct AvatarView: View {
    let avatarId: String?
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = AvatarCache.image(for: avatarId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.secondary.opacity(0.25))
                    Text(initials)
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
