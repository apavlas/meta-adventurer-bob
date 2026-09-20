import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BobBridgeHTTP: Sendable {
    public static let turnPath = "/v0/bob/turn"
    public static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    public static let jsonDecoder = JSONDecoder()

    public static func turnURL(baseURL: URL) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(string: base + turnPath) ?? baseURL.appendingPathComponent("v0").appendingPathComponent("bob").appendingPathComponent("turn")
    }
}

public protocol HTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// URLSession wrapper so Linux (FoundationNetworking) and Apple share one client.
public struct URLSessionHTTP: HTTPPerforming {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: BobBridgeError.sessionCut)
                    return
                }
                continuation.resume(returning: (data, response))
            }.resume()
        }
        #else
        try await session.data(for: request)
        #endif
    }
}

/// HTTPS POST `/v0/bob/turn` with Bearer auth. No production URL is baked in.
public struct HttpsBobTransport: BobTransport {
    public var baseURL: URL
    public var bearerToken: String
    public var http: any HTTPPerforming

    public init(baseURL: URL, bearerToken: String, http: any HTTPPerforming = URLSessionHTTP()) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.http = http
    }

    public func send(_ request: BobBridgeRequest) async throws -> BobBridgeResponse {
        var urlRequest = URLRequest(url: BobBridgeHTTP.turnURL(baseURL: baseURL))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try BobBridgeHTTP.jsonEncoder.encode(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: urlRequest)
        } catch let error as BobBridgeError {
            throw error
        } catch {
            throw BobBridgeError.sessionCut
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BobBridgeError.sessionCut
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try BobBridgeHTTP.jsonDecoder.decode(BobBridgeResponse.self, from: data)
            guard !decoded.spokenLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BobBridgeError.invalidResponse(statusCode: 200)
            }
            return decoded
        case 401:
            throw BobBridgeError.unauthorized
        case 503:
            throw BobBridgeError.cosUnavailable
        default:
            throw BobBridgeError.fromHTTPStatus(httpResponse.statusCode)
        }
    }
}
