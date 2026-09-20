import BobCore
import Foundation

@MainActor
final class CompanionSessionController: ObservableObject {
    enum Phase: String {
        case idle
        case pairing
        case ready
        case listening
        case thinking
        case ended
        case failed
    }

    @Published var phase: Phase = .idle
    @Published var status = "Mock pair not started"
    @Published var registration = "unknown"
    @Published var sessionState = "idle"
    @Published var lastSpoken = ""
    @Published var lastUtterance = ""
    @Published var log = RoundTripLog()
    @Published var liveSTTAvailable = false
    @Published var bridgeMode = "stub"
    @Published var bridgeStatus = "stub (default)"

    private let wearable = DATMockWearableSession()
    private let recognizer = PhoneMicRecognizer()
    private let speaker = SpokenLineSpeaker()
    private var bob: any BobServing
    private var sessionId: String?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        let resolved = BobBridgeConfiguration.makeService(
            environment: environment,
            infoDictionary: infoDictionary
        )
        bob = resolved.service
        bridgeMode = resolved.configuration.resolvedMode.rawValue
        bridgeStatus = resolved.configuration.logLine
    }

    var isListening: Bool { phase == .listening || phase == .thinking }

    func bootstrapMock() async {
        guard phase == .idle || phase == .failed else { return }
        phase = .pairing
        status = "MockDeviceKit.enable → pair .metaGlasses"
        do {
            let paired = try await wearable.pairMetaGlasses()
            registration = wearable.registration
            sessionState = wearable.sessionState
            status = "Paired \(paired.deviceType) · \(paired.note)"
            phase = .ready
            print("[DAT] mock session-up pair ok deviceType=\(paired.deviceType) meta_ai=none")
        } catch {
            phase = .failed
            status = error.localizedDescription
            await speakAndLogFail(
                note: error.localizedDescription,
                sessionId: nil,
                spokenLine: BobBridgeError.failSpokenLine(for: error)
            )
        }
    }

    func talkToBob() async {
        if phase == .idle || phase == .failed {
            await bootstrapMock()
        }
        guard phase == .ready || phase == .ended else { return }

        do {
            status = "Starting DAT DeviceSession"
            let id = try await wearable.startDeviceSession()
            sessionId = id
            sessionState = wearable.sessionState
            registration = wearable.registration
            phase = .listening
            status = "Listening · stt_source=phone_mic"
            await speakAndLog(
                path: .start,
                role: .open,
                line: GoldenSpokenLine.start,
                sessionId: id,
                sttSource: nil,
                sttCapture: nil,
                note: "CTA \(LexCopy.talkToBob)"
            )

            liveSTTAvailable = await recognizer.requestAccess()
            if liveSTTAvailable {
                try? recognizer.start { [weak self] text in
                    Task { await self?.handleUtterance(text, capture: .live) }
                }
            }

            // First proof: one complete round-trip after mock pair + CTA without requiring speech.
            await handleUtterance("What's next?", capture: .demoInjected)
        } catch {
            phase = .failed
            status = error.localizedDescription
            await speakAndLogFail(
                note: error.localizedDescription,
                sessionId: sessionId,
                spokenLine: BobBridgeError.failSpokenLine(for: error)
            )
        }
    }

    func endSession() async {
        recognizer.stop()
        wearable.stopDeviceSession()
        sessionState = wearable.sessionState
        let id = sessionId
        sessionId = nil
        phase = .ended
        status = "Paused"
        await speakAndLog(
            path: .end,
            role: .end,
            line: GoldenSpokenLine.end,
            sessionId: id,
            sttSource: nil,
            sttCapture: nil,
            note: "CTA \(LexCopy.end)"
        )
    }

    func runDemo(_ scenario: StubBobService.Scenario) async {
        guard isListening else { return }
        switch scenario {
        case .reply:
            await handleUtterance("What's next?", capture: .demoInjected)
        case .overBudget:
            await handleUtterance("Give me the full note on desk", capture: .demoInjected)
        case .fail:
            await handleUtterance("fail please", capture: .demoInjected)
        }
    }

    private func handleUtterance(_ text: String, capture: STTCapture) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let sessionId else { return }

        lastUtterance = trimmed
        phase = .thinking
        status = "BobBridge · stt_source=phone_mic · \(capture.rawValue)"

        do {
            let request = BobBridgeRequest(
                utterance: trimmed,
                sttSource: .phoneMic,
                sessionId: sessionId
            )
            let response = try await bob.complete(request)
            let path: GoldenPath = response.spokenLine == GoldenSpokenLine.overBudget ? .overBudget : .reply
            await speakAndLog(
                path: path,
                role: .reply,
                line: response.spokenLine,
                sessionId: sessionId,
                sttSource: .phoneMic,
                sttCapture: capture,
                deskFull: response.deskFull,
                note: "utterance=\(trimmed)"
            )
            phase = .listening
            status = "Listening · stt_source=phone_mic"
        } catch {
            phase = .failed
            recognizer.stop()
            wearable.stopDeviceSession()
            await speakAndLogFail(
                note: String(describing: error),
                sessionId: sessionId,
                spokenLine: BobBridgeError.failSpokenLine(for: error)
            )
        }
    }

    private func speakAndLog(
        path: GoldenPath,
        role: SpokenRole,
        line: String,
        sessionId: String?,
        sttSource: STTSource?,
        sttCapture: STTCapture?,
        deskFull: String? = nil,
        note: String
    ) async {
        lastSpoken = line
        speaker.speak(line)
        let entry = RoundTripEntry(
            path: path,
            deviceType: HardwareContext.deviceTypeLogValue,
            sttSource: sttSource,
            sttCapture: sttCapture,
            sessionId: sessionId,
            spokenLine: line,
            spokenRole: role,
            deskFull: deskFull,
            metaAIUsed: false,
            note: note
        )
        log.append(entry)
    }

    private func speakAndLogFail(note: String, sessionId: String?, spokenLine: String = GoldenSpokenLine.fail) async {
        status = note
        await speakAndLog(
            path: .fail,
            role: .fail,
            line: spokenLine,
            sessionId: sessionId,
            sttSource: .phoneMic,
            sttCapture: nil,
            note: note
        )
    }
}
