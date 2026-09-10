import Foundation
import UIKit

/// Downloads Sleeper avatar thumbnails into the App Group container so the widget
/// extension and Live Activity (which cannot load remote images) can show them.
enum AvatarCache {
    private static var directory: URL? {
        guard let container = SharedStore.containerURL else { return nil }
        let url = container.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileURL(for avatarId: String) -> URL? {
        let safe = avatarId.replacingOccurrences(of: "/", with: "_")
        return directory?.appendingPathComponent(safe).appendingPathExtension("img")
    }

    /// Cached image, if the app has downloaded it before.
    static func image(for avatarId: String?) -> UIImage? {
        guard let avatarId, let url = fileURL(for: avatarId),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Downloads and stores the thumbnail if it is not cached yet. Safe to call often.
    static func prefetch(avatarId: String?, session: URLSession = .shared) async {
        guard let avatarId, let file = fileURL(for: avatarId),
              !FileManager.default.fileExists(atPath: file.path),
              let remote = SleeperAPI.avatarThumbnailURL(for: avatarId) else { return }
        guard let result = try? await session.data(from: remote) else { return }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        guard let image = UIImage(data: data), let png = downscaled(image).pngData() else { return }
        try? png.write(to: file, options: .atomic)
    }

    /// Largest edge, in pixels, of a cached avatar. Live Activities reject images bigger
    /// than their presentation, and the largest avatar we draw is 56 pt.
    static let maxPixelSize: CGFloat = 168

    static func downscaled(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxPixelSize, longest > 0 else { return image }
        let ratio = maxPixelSize / longest
        let target = CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Prefetches both teams' avatars for a snapshot.
    static func prefetch(for snapshot: MatchupSnapshot) async {
        await prefetch(avatarId: snapshot.me.avatarId)
        await prefetch(avatarId: snapshot.opponent?.avatarId)
    }
}
