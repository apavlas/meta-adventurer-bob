import XCTest
@testable import BobCore

final class HFPCaptureGraphTests: XCTestCase {
    func testVoiceProcessingIsOnlyForTheHFPSession() {
        XCTAssertTrue(HFPCaptureGraph.shouldEnableVoiceProcessing(allowsHFP: true))
        XCTAssertFalse(HFPCaptureGraph.shouldEnableVoiceProcessing(allowsHFP: false))
    }

    func testPreferredHFPRateIsWidebandSCO() {
        XCTAssertEqual(HFPCaptureGraph.preferredSampleRate, 16_000)
        XCTAssertEqual(HFPCaptureGraph.preferredIOBufferDuration, 0.02)
        XCTAssertGreaterThan(HFPCaptureGraph.scoFormatSettle, 0)
        XCTAssertLessThan(HFPCaptureGraph.scoFormatSettle, 1)
        XCTAssertGreaterThan(HFPCaptureGraph.tapLogWindow, HFPCaptureGraph.tapLogInterval)
    }

    func testMatchingFormatsDoNotRetargetTheTap() {
        XCTAssertFalse(HFPCaptureGraph.shouldForceHardwareFormat(
            outputRate: 16_000,
            outputChannels: 1,
            hardwareRate: 16_000,
            hardwareChannels: 1
        ))
    }

    func testRateOrChannelMismatchNeedsAnotherNegotiation() {
        XCTAssertTrue(HFPCaptureGraph.shouldForceHardwareFormat(
            outputRate: 48_000,
            outputChannels: 1,
            hardwareRate: 16_000,
            hardwareChannels: 1
        ))
        XCTAssertTrue(HFPCaptureGraph.shouldForceHardwareFormat(
            outputRate: 16_000,
            outputChannels: 2,
            hardwareRate: 16_000,
            hardwareChannels: 1
        ))
    }

    func testUnnegotiatedOutputNeedsAnotherNegotiation() {
        XCTAssertTrue(HFPCaptureGraph.shouldForceHardwareFormat(
            outputRate: 0,
            outputChannels: 0,
            hardwareRate: 8_000,
            hardwareChannels: 1
        ))
        XCTAssertFalse(HFPCaptureGraph.shouldForceHardwareFormat(
            outputRate: 0,
            outputChannels: 0,
            hardwareRate: 0,
            hardwareChannels: 0
        ))
    }

    func testMeasureSilenceAndAKnownSignal() {
        let silence = [Float](repeating: 0, count: 4).withUnsafeBufferPointer { HFPCaptureGraph.measure($0) }
        XCTAssertEqual(silence, LevelReading(rms: 0, peak: 0))

        let tone = [Float(0.5), Float(-0.5)].withUnsafeBufferPointer { HFPCaptureGraph.measure($0) }
        XCTAssertEqual(tone.peak, Float(0.5), accuracy: Float(0.0001))
        XCTAssertEqual(tone.rms, Float(0.5), accuracy: Float(0.0001))

        let empty = [Float]().withUnsafeBufferPointer { HFPCaptureGraph.measure($0) }
        XCTAssertEqual(empty, LevelReading(rms: 0, peak: 0))
    }

    func testLouderChannelWins() {
        let quiet = LevelReading(rms: 0.01, peak: 0.02)
        let speech = LevelReading(rms: 0.1, peak: 0.4)
        XCTAssertEqual(HFPCaptureGraph.louder(quiet, speech), speech)
        XCTAssertEqual(HFPCaptureGraph.louder(speech, quiet), speech)
    }

    func testAudibleEnergyRequiresBuffersAboveTheSilenceFloor() {
        XCTAssertFalse(HFPCaptureGraph.hasAudibleEnergy(peak: 0, bufferCount: 40))
        XCTAssertFalse(HFPCaptureGraph.hasAudibleEnergy(peak: 0.2, bufferCount: 0))
        XCTAssertFalse(HFPCaptureGraph.hasAudibleEnergy(peak: HFPCaptureGraph.silencePeak - 0.001, bufferCount: 8))
        XCTAssertTrue(HFPCaptureGraph.hasAudibleEnergy(peak: HFPCaptureGraph.silencePeak, bufferCount: 8))
    }

    func testDiagnosticLinesIncludeRateEnergyAndPartials() {
        let summary = CaptureEnergySummary(
            bufferCount: 12,
            peak: 0.25,
            rms: 0.5,
            sampleRate: 16_000,
            channels: 1,
            partialEvents: 3
        )
        XCTAssertEqual(
            summary.logFragment,
            "tap_buffers=12 tap_rms=0.5000 tap_peak=0.2500 sample_rate=16000 channels=1 partial_events=3"
        )
        XCTAssertTrue(HFPCaptureGraph.firstBufferLogLine(summary: summary).contains("tap_first"))
        XCTAssertTrue(HFPCaptureGraph.tapEnergyLogLine(seconds: 0.5, summary: summary).contains("t=0.5s"))
        let audible = HFPCaptureGraph.tapEnergySummaryLogLine(audible: true, summary: summary)
        XCTAssertTrue(audible.contains("audible=true"))
        XCTAssertTrue(audible.contains("partial_events=3"))

        let formats = HFPCaptureGraph.formatLogLine(
            sessionRate: 16_000,
            hardwareRate: 16_000,
            hardwareChannels: 1,
            outputRate: 48_000,
            outputChannels: 2,
            voiceProcessing: true
        )
        XCTAssertTrue(formats.contains("session_rate=16000"))
        XCTAssertTrue(formats.contains("hardware_rate=16000"))
        XCTAssertTrue(formats.contains("output_rate=48000"))
        XCTAssertTrue(formats.contains("voice_processing=on"))

        XCTAssertEqual(
            HFPCaptureGraph.partialLogLine(chars: 11, isFinal: false),
            "[Audio] partial chars=11 is_final=false"
        )
    }

    func testNoFinalNoteCarriesTapEvidenceAndStillIsNotAnHFPReply() {
        let capture = CaptureEnergySummary(
            bufferCount: 20,
            peak: 0,
            rms: 0,
            sampleRate: 16_000,
            channels: 1,
            partialEvents: 0
        )
        let note = LiveListenPolicy.noFinalLogNote(
            routeToken: "BluetoothHFP:Meta_Glasses_1H41",
            capture: capture
        )
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
        XCTAssertTrue(entry.consoleLine.contains("speechkit_no_final"))
        XCTAssertTrue(entry.consoleLine.contains("timeout_s=5"))
        XCTAssertTrue(entry.consoleLine.contains("restart_listening"))
        XCTAssertTrue(entry.consoleLine.contains("route=BluetoothHFP:Meta_Glasses_1H41"))
        XCTAssertTrue(entry.consoleLine.contains("tap_buffers=20"))
        XCTAssertTrue(entry.consoleLine.contains("tap_peak=0.0000"))
        XCTAssertTrue(entry.consoleLine.contains("sample_rate=16000"))
        XCTAssertTrue(entry.consoleLine.contains("partial_events=0"))
        XCTAssertFalse(entry.consoleLine.contains("stt_source="))
        XCTAssertFalse(entry.consoleLine.contains("stt_capture="))
    }
}
