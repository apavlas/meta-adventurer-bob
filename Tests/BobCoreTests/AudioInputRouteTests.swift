import XCTest
@testable import BobCore

final class AudioInputRouteTests: XCTestCase {
    func testBluetoothHFPTagsHFPOnTheRealPath() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "BluetoothHFP", portName: "Meta Adventurer")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .hfp)
        XCTAssertEqual(decision.hfpState, .wired)
        XCTAssertEqual(decision.audioRoute, "BluetoothHFP:Meta_Adventurer")
        XCTAssertEqual(decision.loggedRoute, "BluetoothHFP:Meta_Adventurer")
        XCTAssertTrue(decision.statusFragment.contains("stt_source=hfp"))
        XCTAssertTrue(decision.statusFragment.contains("hfp=wired"))
        XCTAssertFalse(decision.statusFragment.contains("not_wired"))
    }

    func testMockPathStaysPhoneMicEvenWhenHFPIsPresent() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "BluetoothHFP", portName: "Meta Adventurer")],
            allowsHFP: false
        )
        XCTAssertEqual(decision.sttSource, .phoneMic)
        XCTAssertEqual(decision.hfpState, .notWired)
        XCTAssertFalse(decision.statusFragment.contains("stt_source=hfp"))
    }

    func testBuiltInMicStaysPhoneMicEvenIfTheNameMentionsGlasses() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "MicrophoneBuiltIn", portName: "Meta Adventurer Hands-Free")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .phoneMic)
        XCTAssertEqual(decision.hfpState, .notWired)
        XCTAssertTrue(decision.audioRoute.contains("MicrophoneBuiltIn"))
        XCTAssertFalse(decision.statusFragment.contains("stt_source=hfp"))
    }

    func testA2DPIsNotAMicrophone() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "BluetoothA2DP", portName: "Meta Adventurer")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .phoneMic)
        XCTAssertEqual(decision.hfpState, .notWired)
        XCTAssertFalse(AudioInputClassifier.isHFPInput(portType: "BluetoothA2DP", portName: "Adventurer Hands-Free"))
    }

    func testWiredHeadsetStaysPhoneMic() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "MicrophoneWired", portName: "Headset Microphone")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .phoneMic)
        XCTAssertEqual(decision.hfpState, .notWired)
    }

    func testClearGlassesHandsFreePortTagsHFP() {
        XCTAssertTrue(
            AudioInputClassifier.isHFPInput(portType: "Headset", portName: "Adventurer Hands-Free")
        )
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "BluetoothLE", portName: "Meta Glasses Hands-Free")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .hfp)
        XCTAssertEqual(decision.hfpState, .wired)
    }

    func testBluetoothLEWithoutHandsFreeMarkerStaysPhoneMic() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "BluetoothLE", portName: "Meta Adventurer")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .phoneMic)
        XCTAssertEqual(decision.hfpState, .notWired)
    }

    func testSCOPortTypeTagsHFP() {
        let decision = AudioInputClassifier.decide(
            inputs: [AudioInputPort(portType: "BluetoothSCO", portName: "Adventurer")],
            allowsHFP: true
        )
        XCTAssertEqual(decision.sttSource, .hfp)
        XCTAssertEqual(decision.hfpState, .wired)
    }

    func testEmptyRouteStaysPhoneMicWithoutAFakeRoute() {
        let decision = AudioInputClassifier.decide(inputs: [], allowsHFP: true)
        XCTAssertEqual(decision.sttSource, .phoneMic)
        XCTAssertEqual(decision.hfpState, .notWired)
        XCTAssertEqual(decision.audioRoute, "none")
        XCTAssertNil(decision.loggedRoute)
        XCTAssertFalse(decision.statusFragment.contains("audio_route="))
    }

    func testPreferredInputPicksGlassesOverAnotherHFPDevice() {
        let inputs = [
            AudioInputPort(portType: "MicrophoneBuiltIn", portName: "iPhone Microphone"),
            AudioInputPort(portType: "BluetoothHFP", portName: "AirPods"),
            AudioInputPort(portType: "BluetoothHFP", portName: "Meta Adventurer"),
        ]
        XCTAssertEqual(AudioInputClassifier.preferredHFPIndex(in: inputs), 2)
        let decision = AudioInputClassifier.decide(inputs: inputs, allowsHFP: true)
        XCTAssertEqual(decision.sttSource, .hfp)
        XCTAssertEqual(decision.portName, "Meta Adventurer")
        XCTAssertTrue(decision.audioRoute.contains("Adventurer"))
    }

    func testPreferredInputUsesTheOnlyHFPPort() {
        let inputs = [
            AudioInputPort(portType: "MicrophoneBuiltIn", portName: "iPhone Microphone"),
            AudioInputPort(portType: "BluetoothHFP", portName: "AirPods"),
        ]
        XCTAssertEqual(AudioInputClassifier.preferredHFPIndex(in: inputs), 1)
    }

    func testRouteTokenStripsSpacesAndColons() {
        XCTAssertEqual(
            AudioInputClassifier.routeToken(portType: "BluetoothHFP", portName: "Meta Glasses"),
            "BluetoothHFP:Meta_Glasses"
        )
        XCTAssertEqual(
            AudioInputClassifier.routeToken(portType: "BluetoothHFP", portName: "A:B"),
            "BluetoothHFP:A_B"
        )
        XCTAssertFalse(
            AudioInputClassifier.routeToken(portType: "BluetoothHFP", portName: "Meta Glasses").contains(" ")
        )
    }

    func testRoundTripLineFlipsHFPWhenTheRouteIsWired() {
        let wired = RoundTripEntry(
            path: .reply,
            sttSource: .hfp,
            sttCapture: .live,
            sessionId: "s-hfp",
            spokenLine: GoldenSpokenLine.reply,
            spokenRole: .reply,
            metaAIUsed: true,
            devicePath: .real,
            hfpState: .wired,
            audioRoute: "BluetoothHFP:Meta_Adventurer",
            note: "utterance=What's next? hfp_wired"
        )
        XCTAssertTrue(wired.consoleLine.contains("stt_source=hfp"))
        XCTAssertTrue(wired.consoleLine.contains("hfp=wired"))
        XCTAssertTrue(wired.consoleLine.contains("audio_route=BluetoothHFP:Meta_Adventurer"))
        XCTAssertTrue(wired.consoleLine.contains("device_path=real"))
        XCTAssertFalse(wired.consoleLine.contains("not_wired"))
        XCTAssertFalse(wired.consoleLine.contains("stt_source=phone_mic"))

        let phone = RoundTripEntry(
            path: .reply,
            sttSource: .phoneMic,
            sttCapture: .live,
            sessionId: "s-mic",
            spokenLine: GoldenSpokenLine.reply,
            spokenRole: .reply,
            metaAIUsed: true,
            devicePath: .real,
            hfpState: .notWired,
            audioRoute: "MicrophoneBuiltIn:iPhone_Microphone",
            note: "hfp_not_wired"
        )
        XCTAssertTrue(phone.consoleLine.contains("stt_source=phone_mic"))
        XCTAssertTrue(phone.consoleLine.contains("hfp=not_wired"))
        XCTAssertTrue(phone.consoleLine.contains("audio_route=MicrophoneBuiltIn:iPhone_Microphone"))
        XCTAssertFalse(phone.consoleLine.contains("stt_source=hfp"))
        XCTAssertFalse(phone.consoleLine.contains("hfp=wired"))
    }

    func testHFPEncodesAsContractValue() throws {
        let request = BobBridgeRequest(utterance: "What's next?", sttSource: .hfp, sessionId: "s-hfp")
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains("\"stt_source\":\"hfp\""))
        XCTAssertFalse(json.contains("phone_mic"))
    }
}
