import Foundation

/// Registers Live Activity push tokens with the optional relay server in `server/`,
/// which then starts and updates the activity via APNs even when the app is closed.
struct RelayClient: Sendable {
    struct Registration: Codable, Hashable {
        /// Stable per-install id so re-registrations replace the old row.
        var installId: String
        var userId: String
        var leagueId: String
        /// Hex-encoded push-to-start token (`Activity.pushToStartTokenUpdates`).
        var pushToStartToken: String?
        /// Hex-encoded token for the currently running activity (`activity.pushTokenUpdates`).
        var activityToken: String?
        /// Activity id the `activityToken` belongs to.
        var activityId: String?
        /// "development" or "production" so the relay picks the right APNs host.
        var environment: String
        var timeZone: String
    }

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `PUT /v1/registrations/<installId>`
    func register(_ registration: Registration) async throws {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("registrations")
            .appendingPathComponent(registration.installId)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        request.timeoutInterval = 15
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SleeperAPIError.httpStatus(http.statusCode)
        }
    }

    /// `DELETE /v1/registrations/<installId>`
    func unregister(installId: String) async throws {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("registrations")
            .appendingPathComponent(installId)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        _ = try await session.data(for: request)
    }

    /// Stable identifier for this install, created on first use.
    static var installId: String {
        let key = "relay.installId"
        if let existing = SharedStore.defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        SharedStore.defaults.set(fresh, forKey: key)
        return fresh
    }

    /// Best guess at the APNs environment this build uses.
    static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}

extension Data {
    /// Push tokens as APNs expects them: lowercase hex.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
