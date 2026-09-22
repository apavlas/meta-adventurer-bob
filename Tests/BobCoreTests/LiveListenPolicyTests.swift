import XCTest
@testable import BobCore

final class LiveListenPolicyTests: XCTestCase {
    func testOnDeviceRecognitionStaysOffForHFP() {
        XCTAssertFalse(LiveListenPolicy.allowsOnDeviceRecognition(sttSource: .hfp, supportsOnDevice: true))
        XCTAssertFalse(LiveListenPolicy.allowsOnDeviceRecognition(sttSource: .hfp, supportsOnDevice: false))
        XCTAssertTrue(LiveListenPolicy.allowsOnDeviceRecognition(sttSource: .phoneMic, supportsOnDevice: true))
        XCTAssertFalse(LiveListenPolicy.allowsOnDeviceRecognition(sttSource: .phoneMic, supportsOnDevice: false))
    }

    func testSilenceBeforeFiveSecondsKeepsWaiting() {
        let action = LiveListenPolicy.decide(
            elapsedSinceListenStart: 4.9,
            partial: "",
            silence: nil,
            endAudioAt: nil
        )
        XCTAssertEqual(action, .wait)
    }

    func testNoPartialAtFiveSecondsIsAPromptNotATranscript() {
        let action = LiveListenPolicy.decide(
            elapsedSinceListenStart: LiveListenPolicy.noFinalTimeout,
            partial: "   ",
            silence: nil,
            endAudioAt: nil
        )
        XCTAssertEqual(action, .missedPrompt)
        XCTAssertEqual(LiveListenPolicy.noFinalTimeout, 5)
    }

    func testFreshPartialIsNotCutOffAtFiveSeconds() {
        let action = LiveListenPolicy.decide(
            elapsedSinceListenStart: 5,
            partial: "What's next",
            silence: 0.2,
            endAudioAt: nil
        )
        XCTAssertEqual(action, .wait)
    }

    func testStablePartialAsksSpeechKitToFinalize() {
        let waiting = LiveListenPolicy.decide(
            elapsedSinceListenStart: 2,
            partial: "What's next",
            silence: LiveListenPolicy.partialSilence - 0.05,
            endAudioAt: nil
        )
        XCTAssertEqual(waiting, .wait)

        let endpoint = LiveListenPolicy.decide(
            elapsedSinceListenStart: 2,
            partial: "What's next",
            silence: LiveListenPolicy.partialSilence,
            endAudioAt: nil
        )
        XCTAssertEqual(endpoint, .endAudio)
    }

    func testMissingFinalPromotesThePartialAfterGrace() {
        let duringGrace = LiveListenPolicy.decide(
            elapsedSinceListenStart: 3.2,
            partial: "What's next",
            silence: 1.2,
            endAudioAt: 3
        )
        XCTAssertEqual(duringGrace, .wait)

        let promoted = LiveListenPolicy.decide(
            elapsedSinceListenStart: 3 + LiveListenPolicy.finalGrace,
            partial: "  What's next  ",
            silence: 1.2,
            endAudioAt: 3
        )
        XCTAssertEqual(promoted, .promotePartial("What's next"))
    }

    func testChangingPartialsStillEndpointByMaxListen() {
        let action = LiveListenPolicy.decide(
            elapsedSinceListenStart: LiveListenPolicy.maxListen,
            partial: "What's next on the calendar",
            silence: 0.1,
            endAudioAt: nil
        )
        XCTAssertEqual(action, .endAudio)
    }

    func testOwnSpokenLinesAreNotUtterances() {
        XCTAssertTrue(LiveListenPolicy.isOwnSpokenEcho(GoldenSpokenLine.start))
        XCTAssertTrue(LiveListenPolicy.isOwnSpokenEcho("Bob here. Listening"))
        XCTAssertTrue(LiveListenPolicy.isOwnSpokenEcho("Didn't catch that, say it again."))
        XCTAssertTrue(LiveListenPolicy.isOwnSpokenEcho(GoldenSpokenLine.noFinal))
        XCTAssertFalse(LiveListenPolicy.isOwnSpokenEcho("What's next?"))
        XCTAssertFalse(LiveListenPolicy.isOwnSpokenEcho("Bob"))

        let echo = LiveListenPolicy.decide(
            elapsedSinceListenStart: 6,
            partial: GoldenSpokenLine.start,
            silence: 2,
            endAudioAt: nil
        )
        XCTAssertEqual(echo, .missedPrompt)
    }

    func testNoFinalLogIsNotAnHFPReply() {
        let note = LiveListenPolicy.noFinalLogNote(routeToken: "BluetoothHFP:Meta_Glasses_1H41")
        let entry = RoundTripEntry(
            path: .noFinal,
            spokenLine: GoldenSpokenLine.noFinal,
            spokenRole: .retry,
            metaAIUsed: true,
            devicePath: .real,
            note: note
        )
        XCTAssertNil(entry.sttSource)
        XCTAssertNil(entry.sttCapture)
        XCTAssertNotEqual(entry.path, .reply)
        XCTAssertTrue(entry.withinCaps)
        XCTAssertTrue(entry.consoleLine.contains("path=no_final"))
        XCTAssertTrue(entry.consoleLine.contains("speechkit_no_final"))
        XCTAssertTrue(entry.consoleLine.contains("timeout_s=5"))
        XCTAssertTrue(entry.consoleLine.contains("restart_listening"))
        XCTAssertTrue(entry.consoleLine.contains("route=BluetoothHFP:Meta_Glasses_1H41"))
        XCTAssertFalse(entry.consoleLine.contains("stt_source="))
        XCTAssertFalse(entry.consoleLine.contains("stt_capture="))
    }

    func testPostRouteSettleFitsInsideTheListenWindow() {
        XCTAssertGreaterThan(LiveListenPolicy.postRouteSettle, 0)
        XCTAssertLessThan(LiveListenPolicy.postRouteSettle, 1)
        XCTAssertLessThan(LiveListenPolicy.partialSilence, LiveListenPolicy.noFinalTimeout)
    }
}
