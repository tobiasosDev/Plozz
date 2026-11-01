import Foundation

/// Configuration for the Trakt integration.
///
/// Native OAuth uses a public client ID, never a client secret. Authentication
/// and media API requests have separate hosts. The HTTPS redirect must exactly
/// match the developer registration and the app's verified Universal Link.
public struct TraktConfig: Sendable, Equatable {
    /// Trakt application client id (also sent as the `trakt-api-key` header).
    public var clientID: String?
    /// Trakt API base URL.
    public var apiBaseURL: URL
    public var authBaseURL: URL
    public var redirectURI: URL

    public init(
        clientID: String? = nil,
        apiBaseURL: URL = URL(string: "https://api.trakt.tv")!,
        authBaseURL: URL = URL(string: "https://auth.trakt.tv")!,
        redirectURI: URL = URL(string: "https://plozz.app/auth/trakt/callback")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.apiBaseURL = apiBaseURL
        self.authBaseURL = authBaseURL
        self.redirectURI = redirectURI
    }

    /// Device-code and PKCE grants both need only a client ID.
    public var isConfigured: Bool {
        clientID != nil
    }

    /// Resolves configuration from the app bundle's Info.plist, falling back to
    /// process-environment variables (handy for tests/CI and local runs).
    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TraktConfig {
        resolved(
            plistClientID: bundle.object(forInfoDictionaryKey: "TraktClientID") as? String,
            plistRedirectURI: bundle.object(forInfoDictionaryKey: "TraktRedirectURI") as? String,
            environment: environment
        )
    }

    /// A registration may list a different redirect than Plozz's default; the
    /// refresh grant must send the registered one. Only an absolute URL counts.
    static func resolved(
        plistClientID: String?,
        plistRedirectURI: String?,
        environment: [String: String]
    ) -> TraktConfig {
        let redirect = (sanitize(plistRedirectURI) ?? sanitize(environment["TRAKT_REDIRECT_URI"]))
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme != nil && $0.host != nil ? $0 : nil }
        var config = TraktConfig(clientID: sanitize(plistClientID) ?? sanitize(environment["TRAKT_CLIENT_ID"]))
        if let redirect { config.redirectURI = redirect }
        return config
    }

    /// Normalizes a raw value: trims whitespace and rejects empty strings and the
    /// unsubstituted build-setting placeholder (`$(TRAKT_CLIENT_ID)`).
    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(")
        else { return nil }
        return trimmed
    }
}
