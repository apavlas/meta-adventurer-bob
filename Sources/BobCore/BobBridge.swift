import Foundation

/// Microphone source tagged on every BobBridge request.
/// v0 mock uses `phone_mic`. Real Adventurer HFP comes later.
public enum STTSource: String, Codable, Sendable, CaseIterable {
    case phoneMic = "phone_mic"
    case hfp = "hfp"
}

public struct BobBridgeRequest: Codable, Equatable, Sendable {
    public var utterance: String
    public var sttSource: STTSource
    public var sessionId: String

    public init(utterance: String, sttSource: STTSource, sessionId: String) {
        self.utterance = utterance
        self.sttSource = sttSource
        self.sessionId = sessionId
    }

    enum CodingKeys: String, CodingKey {
        case utterance
        case sttSource = "stt_source"
        case sessionId = "session_id"
    }
}

public struct BobBridgeResponse: Codable, Equatable, Sendable {
    public var spokenLine: String
    public var deskFull: String?

    public init(spokenLine: String, deskFull: String? = nil) {
        self.spokenLine = spokenLine
        self.deskFull = deskFull
    }

    enum CodingKeys: String, CodingKey {
        case spokenLine = "spoken_line"
        case deskFull = "desk_full"
    }
}

public enum BobBridgeError: Error, Equatable, Sendable {
    case sessionCut
    case unauthorized
    case cosUnavailable
    case remoteEndpointNotConfigured
    case invalidResponse(statusCode: Int)

    /// Lex fail line for 401 / 503 / other session cuts.
    public var failSpokenLine: String { GoldenSpokenLine.fail }

    public static func failSpokenLine(for error: Error) -> String {
        (error as? BobBridgeError)?.failSpokenLine ?? GoldenSpokenLine.fail
    }

    public static func fromHTTPStatus(_ statusCode: Int) -> BobBridgeError {
        switch statusCode {
        case 401: return .unauthorized
        case 503: return .cosUnavailable
        default: return .invalidResponse(statusCode: statusCode)
        }
    }
}

/// Transport-agnostic Bob. Use `HttpsBobTransport` for POST `/v0/bob/turn`.
/// WebSocket is deferred until barge-in. Do not invent a live Bob API URL.
public protocol BobServing: Sendable {
    func complete(_ request: BobBridgeRequest) async throws -> BobBridgeResponse
}

public protocol BobTransport: Sendable {
    func send(_ request: BobBridgeRequest) async throws -> BobBridgeResponse
}

/// Sentinel when remote credentials are absent. Prefer `HttpsBobTransport`.
public struct UnconfiguredRemoteBobTransport: BobTransport {
    public var endpoint: String?

    public init(endpoint: String? = nil) {
        self.endpoint = endpoint
    }

    public func send(_ request: BobBridgeRequest) async throws -> BobBridgeResponse {
        _ = request
        throw BobBridgeError.remoteEndpointNotConfigured
    }
}

public struct BobBridgeClient: BobServing {
    private let transport: any BobTransport

    public init(transport: any BobTransport) {
        self.transport = transport
    }

    public func complete(_ request: BobBridgeRequest) async throws -> BobBridgeResponse {
        do {
            let raw = try await transport.send(request)
            return SpokenCaps.enforceReply(spokenLine: raw.spokenLine, deskFull: raw.deskFull)
        } catch let error as BobBridgeError {
            throw error
        } catch {
            throw BobBridgeError.sessionCut
        }
    }
}
