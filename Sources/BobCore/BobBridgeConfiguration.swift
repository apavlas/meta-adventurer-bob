import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves stub vs remote BobBridge. Missing URL or token keeps the offline stub.
public struct BobBridgeConfiguration: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case stub
        case remote
    }

    public static let modeKey = "BOB_BRIDGE_MODE"
    public static let baseURLKey = "BOB_BRIDGE_BASE_URL"
    public static let bearerTokenKey = "BOB_BRIDGE_BEARER_TOKEN"

    public var requestedMode: Mode
    public var resolvedMode: Mode
    public var baseURL: URL?
    public var bearerTokenPresent: Bool
    public var fallbackReason: String?

    public var isRemote: Bool { resolvedMode == .remote }

    public var logLine: String {
        var parts = [
            "[BobBridge] requested=\(requestedMode.rawValue)",
            "resolved=\(resolvedMode.rawValue)",
        ]
        if let baseURL {
            parts.append("base_url=\(baseURL.absoluteString)")
        }
        parts.append("bearer=\(bearerTokenPresent ? "set" : "missing")")
        if let fallbackReason {
            parts.append("reason=\(fallbackReason)")
        }
        return parts.joined(separator: " ")
    }

    public init(
        requestedMode: Mode,
        resolvedMode: Mode,
        baseURL: URL?,
        bearerTokenPresent: Bool,
        fallbackReason: String?
    ) {
        self.requestedMode = requestedMode
        self.resolvedMode = resolvedMode
        self.baseURL = baseURL
        self.bearerTokenPresent = bearerTokenPresent
        self.fallbackReason = fallbackReason
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = [:]
    ) -> (configuration: BobBridgeConfiguration, bearerToken: String?) {
        let requested = parseMode(
            firstNonEmpty([
                environment[modeKey],
                infoDictionary[modeKey] as? String,
            ]) ?? Mode.stub.rawValue
        )
        let urlString = firstNonEmpty([
            environment[baseURLKey],
            infoDictionary[baseURLKey] as? String,
        ])
        let token = firstNonEmpty([
            environment[bearerTokenKey],
            infoDictionary[bearerTokenKey] as? String,
        ])
        let url = urlString.flatMap(URL.init(string:))

        if requested == .stub {
            let config = BobBridgeConfiguration(
                requestedMode: .stub,
                resolvedMode: .stub,
                baseURL: url,
                bearerTokenPresent: token != nil,
                fallbackReason: nil
            )
            return (config, nil)
        }

        if urlString == nil || url == nil {
            return fallback(
                requested: .remote,
                url: nil,
                token: token,
                reason: "\(baseURLKey) missing — staying on stub"
            )
        }
        if let url, !isAllowedBaseURL(url) {
            return fallback(
                requested: .remote,
                url: url,
                token: token,
                reason: "\(baseURLKey) must be https (localhost http allowed for tests)"
            )
        }
        if token == nil {
            return fallback(
                requested: .remote,
                url: url,
                token: nil,
                reason: "\(bearerTokenKey) missing — staying on stub"
            )
        }

        let config = BobBridgeConfiguration(
            requestedMode: .remote,
            resolvedMode: .remote,
            baseURL: url,
            bearerTokenPresent: true,
            fallbackReason: nil
        )
        return (config, token)
    }

    public static func makeService(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = [:],
        http: (any HTTPPerforming)? = nil
    ) -> (service: any BobServing, configuration: BobBridgeConfiguration) {
        let resolved = resolve(environment: environment, infoDictionary: infoDictionary)
        print(resolved.configuration.logLine)
        if resolved.configuration.resolvedMode == .remote,
           let baseURL = resolved.configuration.baseURL,
           let token = resolved.bearerToken
        {
            let transport = HttpsBobTransport(
                baseURL: baseURL,
                bearerToken: token,
                http: http ?? URLSessionHTTP()
            )
            return (BobBridgeClient(transport: transport), resolved.configuration)
        }
        return (StubBobService(scenario: .reply), resolved.configuration)
    }

    public static func isAllowedBaseURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return true }
        let host = url.host?.lowercased()
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    private static func parseMode(_ raw: String) -> Mode {
        Mode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .stub
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            if trimmed.hasPrefix("$(") && trimmed.hasSuffix(")") {
                continue
            }
            return trimmed
        }
        return nil
    }

    private static func fallback(
        requested: Mode,
        url: URL?,
        token: String?,
        reason: String
    ) -> (configuration: BobBridgeConfiguration, bearerToken: String?) {
        let config = BobBridgeConfiguration(
            requestedMode: requested,
            resolvedMode: .stub,
            baseURL: url,
            bearerTokenPresent: token != nil,
            fallbackReason: reason
        )
        return (config, nil)
    }
}
