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
    case remoteEndpointNotConfigured
}

/// Transport-agnostic Bob. Swap `StubBobService` for an HTTP/WS client later.
/// Do not invent a live Bob API URL.
public protocol BobServing: Sendable {
    func complete(_ request: BobBridgeRequest) async throws -> BobBridgeResponse
}

/// Future remote transport. `endpoint` must be injected by the host app; v0 leaves it nil.
public protocol BobTransport: Sendable {
    func send(_ request: BobBridgeRequest) async throws -> BobBridgeResponse
}

public struct UnconfiguredRemoteBobTransport: BobTransport {
    public var endpoint: String?

    public init(endpoint: String? = nil) {
        self.endpoint = endpoint
    }

    public func send(_ request: BobBridgeRequest) async throws -> BobBridgeResponse {
        _ = request
        guard endpoint != nil else {
            throw BobBridgeError.remoteEndpointNotConfigured
        }
        throw BobBridgeError.remoteEndpointNotConfigured
    }
}

public struct BobBridgeClient: BobServing {
    private let transport: any BobTransport

    public init(transport: any BobTransport) {
        self.transport = transport
    }

    public func complete(_ request: BobBridgeRequest) async throws -> BobBridgeResponse {
        let raw = try await transport.send(request)
        return SpokenCaps.enforceReply(spokenLine: raw.spokenLine, deskFull: raw.deskFull)
    }
}
