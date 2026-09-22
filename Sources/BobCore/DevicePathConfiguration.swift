import Foundation

/// Which DAT stack the companion boots.
/// `mock` enables MockDeviceKit. `real` uses Meta AI registration and never calls `MockDeviceKit.enable`.
public enum DevicePathKind: String, Codable, Sendable {
    case mock
    case real
}

/// Resolves `BOB_USE_MOCK_DEVICE`. Missing, blank, unexpanded `$(…)`, or anything other than an explicit YES is **real** (mock off).
///
/// Accepted YES tokens: `YES`, `yes`, `true`, `1`, `y`.
/// Resolution order matches BobBridge: process environment, then Info.plist.
public struct DevicePathConfiguration: Equatable, Sendable {
    public static let key = "BOB_USE_MOCK_DEVICE"

    public var useMockDevice: Bool
    public var rawValue: String?

    public var path: DevicePathKind { useMockDevice ? .mock : .real }

    public var logLine: String {
        let shown = rawValue ?? "unset"
        return "[DAT] \(Self.key)=\(shown) resolved=\(path.rawValue) mock_kit=\(useMockDevice ? "enable" : "off")"
    }

    public init(useMockDevice: Bool, rawValue: String?) {
        self.useMockDevice = useMockDevice
        self.rawValue = rawValue
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = [:]
    ) -> DevicePathConfiguration {
        let raw = firstNonEmpty([
            environment[key],
            infoDictionary[key] as? String,
        ])
        return DevicePathConfiguration(useMockDevice: parseYes(raw), rawValue: raw)
    }

    /// Explicit YES only. Default and every other token stay on the real path.
    public static func parseYes(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1", "y":
            return true
        default:
            return false
        }
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
}
