import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BobCore

private struct MockHTTP: HTTPPerforming, Sendable {
    var statusCode: Int
    var body: Data
    var captured: @Sendable (URLRequest) -> Void = { _ in }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured(request)
        let url = request.url ?? URL(string: "https://bob-bridge.example.invalid/v0/bob/turn")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

final class HttpsBobTransportTests: XCTestCase {
    private let sampleRequest = BobBridgeRequest(
        utterance: "What's next?",
        sttSource: .phoneMic,
        sessionId: "session-demo"
    )

    func testRequestEncodingUsesLockedSnakeCaseKeys() throws {
        let data = try BobBridgeHTTP.jsonEncoder.encode(sampleRequest)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("request JSON is not an object")
        }
        XCTAssertEqual(object["session_id"] as? String, "session-demo")
        XCTAssertEqual(object["utterance"] as? String, "What's next?")
        XCTAssertEqual(object["stt_source"] as? String, "phone_mic")
        XCTAssertEqual(object.count, 3)
        XCTAssertEqual(BobBridgeHTTP.turnPath, "/v0/bob/turn")
    }

    func testResponseDecodingSpokenLineRequiredDeskFullOptional() throws {
        let withNull = Data(#"{"spoken_line":"Next up is the 2pm with Sue.","desk_full":null}"#.utf8)
        let decodedNull = try BobBridgeHTTP.jsonDecoder.decode(BobBridgeResponse.self, from: withNull)
        XCTAssertEqual(decodedNull.spokenLine, GoldenSpokenLine.reply)
        XCTAssertNil(decodedNull.deskFull)

        let omitted = Data(#"{"spoken_line":"Next up is the 2pm with Sue."}"#.utf8)
        let decodedOmitted = try BobBridgeHTTP.jsonDecoder.decode(BobBridgeResponse.self, from: omitted)
        XCTAssertNil(decodedOmitted.deskFull)

        let withDesk = Data(#"{"spoken_line":"Full note on desk.","desk_full":"longer desk text"}"#.utf8)
        let decodedDesk = try BobBridgeHTTP.jsonDecoder.decode(BobBridgeResponse.self, from: withDesk)
        XCTAssertEqual(decodedDesk.spokenLine, GoldenSpokenLine.overBudget)
        XCTAssertEqual(decodedDesk.deskFull, "longer desk text")
    }

    func testHTTPS200AppliesClientSpokenCaps() async throws {
        let overBudgetBody = try BobBridgeHTTP.jsonEncoder.encode(
            BobBridgeResponse(spokenLine: StubBobService.longDeskAnswer, deskFull: nil)
        )
        let transport = HttpsBobTransport(
            baseURL: URL(string: "https://bob-bridge.example.invalid")!,
            bearerToken: "test-token",
            http: MockHTTP(statusCode: 200, body: overBudgetBody)
        )
        let response = try await BobBridgeClient(transport: transport).complete(sampleRequest)
        XCTAssertEqual(response.spokenLine, GoldenSpokenLine.overBudget)
        XCTAssertEqual(response.deskFull, StubBobService.longDeskAnswer)
    }

    func testHTTPSPostsTurnPathAndBearer() async throws {
        final class RequestBox: @unchecked Sendable {
            var request: URLRequest?
        }
        let box = RequestBox()
        let body = try BobBridgeHTTP.jsonEncoder.encode(
            BobBridgeResponse(spokenLine: GoldenSpokenLine.reply, deskFull: nil)
        )
        let http = MockHTTP(statusCode: 200, body: body) { request in
            box.request = request
        }
        let transport = HttpsBobTransport(
            baseURL: URL(string: "https://bob-bridge.example.invalid/")!,
            bearerToken: "test-token",
            http: http
        )
        _ = try await transport.send(sampleRequest)
        guard let request = box.request else {
            return XCTFail("missing captured request")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://bob-bridge.example.invalid/v0/bob/turn")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testHTTP503MapsToFailSpokenLine() async {
        let transport = HttpsBobTransport(
            baseURL: URL(string: "https://bob-bridge.example.invalid")!,
            bearerToken: "test-token",
            http: MockHTTP(statusCode: 503, body: Data(#"{"error":"CoS unavailable"}"#.utf8))
        )
        do {
            _ = try await BobBridgeClient(transport: transport).complete(sampleRequest)
            XCTFail("expected 503")
        } catch let error as BobBridgeError {
            XCTAssertEqual(error, .cosUnavailable)
            XCTAssertEqual(error.failSpokenLine, GoldenSpokenLine.fail)
            XCTAssertEqual(error.failSpokenLine, "Session cut — check the phone.")
            XCTAssertEqual(SpokenCaps.sentenceCount(error.failSpokenLine), 1)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTP401MapsToFailSpokenLine() async {
        let transport = HttpsBobTransport(
            baseURL: URL(string: "https://bob-bridge.example.invalid")!,
            bearerToken: "bad-token",
            http: MockHTTP(statusCode: 401, body: Data())
        )
        do {
            _ = try await BobBridgeClient(transport: transport).complete(sampleRequest)
            XCTFail("expected 401")
        } catch let error as BobBridgeError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertEqual(BobBridgeError.failSpokenLine(for: error), GoldenSpokenLine.fail)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMissingRemoteCredentialsStayOnStub() {
        let resolved = BobBridgeConfiguration.resolve(
            environment: [
                "BOB_BRIDGE_MODE": "remote",
            ],
            infoDictionary: [:]
        )
        XCTAssertEqual(resolved.configuration.requestedMode, .remote)
        XCTAssertEqual(resolved.configuration.resolvedMode, .stub)
        XCTAssertNil(resolved.bearerToken)
        XCTAssertTrue(resolved.configuration.fallbackReason?.contains("BOB_BRIDGE_BASE_URL") == true)
        XCTAssertTrue(resolved.configuration.logLine.contains("staying on stub"))

        let missingToken = BobBridgeConfiguration.resolve(
            environment: [
                "BOB_BRIDGE_MODE": "remote",
                "BOB_BRIDGE_BASE_URL": "https://bob-bridge.example.invalid",
            ],
            infoDictionary: [:]
        )
        XCTAssertEqual(missingToken.configuration.resolvedMode, .stub)
        XCTAssertTrue(missingToken.configuration.fallbackReason?.contains("BOB_BRIDGE_BEARER_TOKEN") == true)
    }

    func testRemoteModeRequiresHTTPSAndToken() {
        let httpRejected = BobBridgeConfiguration.resolve(
            environment: [
                "BOB_BRIDGE_MODE": "remote",
                "BOB_BRIDGE_BASE_URL": "http://evil.example",
                "BOB_BRIDGE_BEARER_TOKEN": "secret",
            ]
        )
        XCTAssertEqual(httpRejected.configuration.resolvedMode, .stub)

        let ok = BobBridgeConfiguration.resolve(
            environment: [
                "BOB_BRIDGE_MODE": "remote",
                "BOB_BRIDGE_BASE_URL": "https://bob-bridge.example.invalid",
                "BOB_BRIDGE_BEARER_TOKEN": "secret",
            ]
        )
        XCTAssertEqual(ok.configuration.resolvedMode, .remote)
        XCTAssertEqual(ok.bearerToken, "secret")
        XCTAssertTrue(ok.configuration.bearerTokenPresent)
        XCTAssertFalse(ok.configuration.logLine.contains("secret"))
    }

    func testUnexpandedInfoPlistPlaceholdersAreIgnored() {
        let resolved = BobBridgeConfiguration.resolve(
            environment: [:],
            infoDictionary: [
                "BOB_BRIDGE_MODE": "remote",
                "BOB_BRIDGE_BASE_URL": "$(BOB_BRIDGE_BASE_URL)",
                "BOB_BRIDGE_BEARER_TOKEN": "$(BOB_BRIDGE_BEARER_TOKEN)",
            ]
        )
        XCTAssertEqual(resolved.configuration.resolvedMode, .stub)
    }

    func testFactoryUsesStubWhenRemoteIncomplete() {
        let made = BobBridgeConfiguration.makeService(
            environment: ["BOB_BRIDGE_MODE": "remote"],
            infoDictionary: [:]
        )
        XCTAssertEqual(made.configuration.resolvedMode, .stub)
        XCTAssertTrue(made.service is StubBobService)
    }
}
