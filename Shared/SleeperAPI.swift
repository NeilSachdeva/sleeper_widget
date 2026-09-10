import Foundation

enum SleeperAPIError: LocalizedError, Equatable {
    case invalidURL
    case notFound
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Sleeper URL."
        case .notFound: return "Not found on Sleeper."
        case .httpStatus(let code): return "Sleeper returned HTTP \(code)."
        case .decoding(let detail): return "Could not read Sleeper's response (\(detail))."
        }
    }
}

/// Thin async client for Sleeper's public, unauthenticated read API.
/// Stay under ~1000 calls/minute per Sleeper's guidance; this app makes a handful per refresh.
struct SleeperAPI: Sendable {
    static let baseURL = URL(string: "https://api.sleeper.app/v1")!
    static let avatarBaseURL = URL(string: "https://sleepercdn.com/avatars")!

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Endpoints

    /// `GET /v1/user/<username or user_id>`
    func user(_ usernameOrId: String) async throws -> SleeperUser {
        let trimmed = usernameOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SleeperAPIError.notFound }
        // Display names with spaces or symbols are common input; encode rather than fail.
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return try await get(path: "user/\(encoded)")
    }

    /// `GET /v1/user/<user_id>/leagues/<sport>/<season>`
    func leagues(userId: String, season: String, sport: String = AppConfig.sport) async throws -> [SleeperLeague] {
        try await get(path: "user/\(userId)/leagues/\(sport)/\(season)")
    }

    /// `GET /v1/league/<league_id>`
    func league(_ leagueId: String) async throws -> SleeperLeague {
        try await get(path: "league/\(leagueId)")
    }

    /// `GET /v1/league/<league_id>/rosters`
    func rosters(leagueId: String) async throws -> [SleeperRoster] {
        try await get(path: "league/\(leagueId)/rosters")
    }

    /// `GET /v1/league/<league_id>/users`
    func users(leagueId: String) async throws -> [SleeperLeagueUser] {
        try await get(path: "league/\(leagueId)/users")
    }

    /// `GET /v1/league/<league_id>/matchups/<week>`
    func matchups(leagueId: String, week: Int) async throws -> [SleeperMatchup] {
        try await get(path: "league/\(leagueId)/matchups/\(week)")
    }

    /// `GET /v1/state/<sport>`
    func state(sport: String = AppConfig.sport) async throws -> SleeperState {
        try await get(path: "state/\(sport)")
    }

    /// Thumbnail URL for a Sleeper avatar id (`nil` when the user has no avatar).
    static func avatarThumbnailURL(for avatarId: String?) -> URL? {
        guard let avatarId, !avatarId.isEmpty else { return nil }
        return avatarBaseURL.appendingPathComponent("thumbs").appendingPathComponent(avatarId)
    }

    // MARK: Transport

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: Self.baseURL.absoluteString + "/" + path) else {
            throw SleeperAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 404: throw SleeperAPIError.notFound
            default: throw SleeperAPIError.httpStatus(http.statusCode)
            }
        }
        // Sleeper answers some lookups (unknown user, empty week) with a bare `null`.
        if data.isEmpty || String(decoding: data.prefix(4), as: UTF8.self) == "null" {
            throw SleeperAPIError.notFound
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw SleeperAPIError.decoding(String(describing: error))
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
