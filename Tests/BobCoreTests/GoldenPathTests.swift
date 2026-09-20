import Foundation
import XCTest
@testable import BobCore

final class GoldenPathTests: XCTestCase {
    func testGoldenSpokenLinesMatchLockedCopy() {
        XCTAssertEqual(GoldenSpokenLine.start, "Bob here. Listening.")
        XCTAssertEqual(GoldenSpokenLine.reply, "Next up is the 2pm with Sue.")
        XCTAssertEqual(GoldenSpokenLine.overBudget, "Full note on desk.")
        XCTAssertEqual(GoldenSpokenLine.fail, "Session cut — check the phone.")
        XCTAssertEqual(GoldenSpokenLine.end, "Paused — say Bob when you’re back.")
    }

    func testLexCopyIsExact() {
        XCTAssertEqual(LexCopy.talkToBob, "Talk to Bob")
        XCTAssertEqual(LexCopy.sessionSubtext, "Opens a hands-free session")
        XCTAssertEqual(LexCopy.end, "End")
    }

    func testGoldenLinesSitInsideCaps() {
        XCTAssertTrue(SpokenCaps.isWithinCaps(role: .open, spokenLine: GoldenSpokenLine.start))
        XCTAssertTrue(SpokenCaps.isWithinCaps(role: .reply, spokenLine: GoldenSpokenLine.reply))
        XCTAssertTrue(SpokenCaps.isWithinCaps(role: .reply, spokenLine: GoldenSpokenLine.overBudget))
        XCTAssertTrue(SpokenCaps.isWithinCaps(role: .fail, spokenLine: GoldenSpokenLine.fail))
        XCTAssertTrue(SpokenCaps.isWithinCaps(role: .end, spokenLine: GoldenSpokenLine.end))
        XCTAssertLessThanOrEqual(SpokenCaps.wordCount(GoldenSpokenLine.start), SpokenCaps.openMaxWords)
        XCTAssertLessThanOrEqual(SpokenCaps.wordCount(GoldenSpokenLine.reply), SpokenCaps.replyMaxWords)
        XCTAssertEqual(SpokenCaps.sentenceCount(GoldenSpokenLine.fail), 1)
        XCTAssertEqual(SpokenCaps.sentenceCount(GoldenSpokenLine.end), 1)
    }

    func testLongDeskAnswerIsOverBudget() {
        XCTAssertFalse(SpokenCaps.isWithinCaps(role: .reply, spokenLine: StubBobService.longDeskAnswer))
        XCTAssertGreaterThan(SpokenCaps.wordCount(StubBobService.longDeskAnswer), SpokenCaps.replyMaxWords)
        XCTAssertGreaterThan(SpokenCaps.sentenceCount(StubBobService.longDeskAnswer), SpokenCaps.replyMaxSentences)
    }

    func testEnforceReplyCollapsesOverBudgetToDeskPointer() {
        let capped = SpokenCaps.enforceReply(
            spokenLine: StubBobService.longDeskAnswer,
            deskFull: nil
        )
        XCTAssertEqual(capped.spokenLine, GoldenSpokenLine.overBudget)
        XCTAssertEqual(capped.deskFull, StubBobService.longDeskAnswer)
    }

    func testStubReplyRoundTrip() async throws {
        let bob = StubBobService(scenario: .reply)
        let response = try await bob.complete(
            BobBridgeRequest(
                utterance: "What's next?",
                sttSource: .phoneMic,
                sessionId: "session-demo"
            )
        )
        XCTAssertEqual(response.spokenLine, GoldenSpokenLine.reply)
        XCTAssertNil(response.deskFull)
        XCTAssertTrue(SpokenCaps.isWithinCaps(role: .reply, spokenLine: response.spokenLine))
    }

    func testStubOverBudgetRoundTrip() async throws {
        let bob = StubBobService(scenario: .overBudget)
        let response = try await bob.complete(
            BobBridgeRequest(
                utterance: "Give me the full note on desk",
                sttSource: .phoneMic,
                sessionId: "session-demo"
            )
        )
        XCTAssertEqual(response.spokenLine, GoldenSpokenLine.overBudget)
        XCTAssertEqual(response.deskFull, StubBobService.longDeskAnswer)
    }

    func testStubFailThrowsSessionCut() async {
        let bob = StubBobService(scenario: .fail)
        do {
            _ = try await bob.complete(
                BobBridgeRequest(
                    utterance: "fail please",
                    sttSource: .phoneMic,
                    sessionId: "session-demo"
                )
            )
            XCTFail("expected session cut")
        } catch let error as BobBridgeError {
            XCTAssertEqual(error, .sessionCut)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRemoteTransportIsUnconfigured() async {
        let transport = UnconfiguredRemoteBobTransport()
        do {
            _ = try await transport.send(
                BobBridgeRequest(utterance: "hi", sttSource: .phoneMic, sessionId: "x")
            )
            XCTFail("expected unconfigured")
        } catch let error as BobBridgeError {
            XCTAssertEqual(error, .remoteEndpointNotConfigured)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRoundTripLogRecordsStartAndReply() {
        var log = RoundTripLog()
        log.append(RoundTripEntry(path: .start, spokenLine: GoldenSpokenLine.start, spokenRole: .open))
        log.append(
            RoundTripEntry(
                path: .reply,
                sttSource: .phoneMic,
                sttCapture: .demoInjected,
                sessionId: "s1",
                spokenLine: GoldenSpokenLine.reply,
                spokenRole: .reply
            )
        )
        XCTAssertTrue(log.hasCompleteReplyRoundTrip)
        XCTAssertTrue(log.entries[0].consoleLine.contains("stt_source=phone_mic"))
        XCTAssertTrue(log.entries[0].consoleLine.contains("deviceType=META_GLASSES"))
        XCTAssertEqual(HardwareContext.deviceTypeLogValue, "META_GLASSES")
    }

    func testJSONUsesSnakeCaseContractKeys() throws {
        let request = BobBridgeRequest(
            utterance: "What's next?",
            sttSource: .phoneMic,
            sessionId: "abc"
        )
        let requestData = try JSONEncoder().encode(request)
        let requestJSON = String(decoding: requestData, as: UTF8.self)
        XCTAssertTrue(requestJSON.contains("\"stt_source\":\"phone_mic\""))
        XCTAssertTrue(requestJSON.contains("\"session_id\":\"abc\""))

        let response = BobBridgeResponse(spokenLine: GoldenSpokenLine.overBudget, deskFull: "longer")
        let responseJSON = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertTrue(responseJSON.contains("\"spoken_line\""))
        XCTAssertTrue(responseJSON.contains("\"desk_full\""))
    }
}
