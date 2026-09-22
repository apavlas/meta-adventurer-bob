import BobCore
import Foundation

struct PairedGlasses: Sendable {
    var deviceType: String
    var glassesModel: String
    var note: String
    var metaAIUsed: Bool
}

enum WearableSessionError: Error, LocalizedError {
    case mockKitUnavailable
    case datUnavailable
    case pairFailed(String)
    case sessionFailed(String)
    case notPaired
    case registrationFailed(String)
    case noMetaGlasses

    var errorDescription: String? {
        switch self {
        case .mockKitUnavailable:
            return "MockDeviceKit is not linked in this build."
        case .datUnavailable:
            return "MWDATCore is not linked in this build."
        case .pairFailed(let message):
            return message
        case .sessionFailed(let message):
            return message
        case .notPaired:
            return "Select .metaGlasses before starting a session."
        case .registrationFailed(let message):
            return message
        case .noMetaGlasses:
            return "No .metaGlasses device in DAT devicesStream. Meta AI must show the Adventurer as Connected, with Developer Mode on."
        }
    }
}

/// Mock or real DAT session. The real implementation must not reference MockDeviceKit.
@MainActor
protocol WearableSessionControlling: AnyObject {
    var registration: String { get }
    var sessionState: String { get }
    var metaAIUsed: Bool { get }
    var isReadyToStartSession: Bool { get }
    var onChange: (@MainActor () -> Void)? { get set }
    func prepare() async throws -> PairedGlasses
    func startDeviceSession() async throws -> String
    func stopDeviceSession()
}
