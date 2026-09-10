import Foundation

enum RelayClientError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return code == 401 || code == 403
                ? "Relay rejected the token (HTTP \(code))."
                : "Relay returned HTTP \(code)."
        }
    }
}

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
        /// True when the user pinned the activity by hand; the relay then keeps it
        /// alive between game windows instead of ending it.
        var startedManually: Bool
        /// ISO 8601 time until which the relay must not push-to-start (the user tapped Stop).
        var suppressAutoStartUntil: String?
    }

    let baseURL: URL
    let authToken: String?
    let session: URLSession

    init(baseURL: URL, authToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authToken = authToken
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
        authorize(&request)
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RelayClientError.httpStatus(http.statusCode)
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
        authorize(&request)
        _ = try await session.data(for: request)
    }

    /// Adds `Authorization: Bearer …` when the relay is protected with RELAY_AUTH_TOKEN.
    private func authorize(_ request: inout URLRequest) {
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Stable identifier for this install, created on first use.
    static var installId: String {
        let key = "relay.installId"
        if let existing = SharedStore.defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        SharedStore.defaults.set(fresh, forKey: key)
        return fresh
    }

    /// The APNs environment this build's tokens belong to. Read from the signed
    /// provisioning profile (`aps-environment`), since a Release build run from Xcode
    /// still uses the sandbox; falls back to the build configuration on the simulator.
    static let apnsEnvironment: String = {
        if let fromProfile = provisioningProfileAPSEnvironment() { return fromProfile }
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }()

    private static func provisioningProfileAPSEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), in: start.upperBound..<raw.endIndex)
        else { return nil }
        let plistData = raw.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String,
              environment == "development" || environment == "production"
        else { return nil }
        return environment
    }
}

extension Data {
    /// Push tokens as APNs expects them: lowercase hex.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
