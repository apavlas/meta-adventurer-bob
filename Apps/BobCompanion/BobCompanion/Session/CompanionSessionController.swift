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
    @Published var status = "Real DAT not started"
    @Published var registration = "unknown"
    @Published var sessionState = "idle"
    @Published var lastSpoken = ""
    @Published var lastUtterance = ""
    @Published var log = RoundTripLog()
    @Published var liveSTTAvailable = false
    @Published var bridgeMode = "stub"
    @Published var bridgeStatus = "stub (default)"

    let usesMockDevice: Bool
    let devicePath: DevicePathKind

    private let wearable: any WearableSessionControlling
    private let recognizer = PhoneMicRecognizer()
    private let speaker = SpokenLineSpeaker()
    private var bob: any BobServing
    private var sessionId: String?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        let path = DevicePathConfiguration.resolve(
            environment: environment,
            infoDictionary: infoDictionary
        )
        usesMockDevice = path.useMockDevice
        devicePath = path.path
        wearable = path.useMockDevice ? DATMockWearableSession() : DATRealWearableSession()
        status = path.useMockDevice ? "Mock pair not started" : "Real DAT not started"

        let resolved = BobBridgeConfiguration.makeService(
            environment: environment,
            infoDictionary: infoDictionary
        )
        bob = resolved.service
        bridgeMode = resolved.configuration.resolvedMode.rawValue
        bridgeStatus = resolved.configuration.logLine
        print(path.logLine)

        wearable.onChange = { [weak self] in
            self?.syncWearableFields()
        }
    }

    var isListening: Bool { phase == .listening || phase == .thinking }

    var metaAIUsed: Bool { wearable.metaAIUsed }

    /// Honest capture tag. HFP is not wired on either path.
    var sttSummary: String {
        let mic = liveSTTAvailable ? "live" : "mic not granted"
        let ai = metaAIUsed ? "used" : "none"
        return "stt_source=phone_mic (\(mic)) · hfp=not_wired · meta_ai=\(ai)"
    }

    func bootstrap() async {
        guard phase == .idle || phase == .failed || phase == .pairing else { return }
        phase = .pairing
        status = usesMockDevice
            ? "MockDeviceKit.enable → pair .metaGlasses"
            : "Meta AI registration"
        do {
            let paired = try await wearable.prepare()
            syncWearableFields()
            if wearable.isReadyToStartSession {
                status = readyStatus(paired)
                phase = .ready
                let ai = paired.metaAIUsed ? "used" : "none"
                print("[DAT] session-up device_path=\(devicePath.rawValue) deviceType=\(paired.deviceType) meta_ai=\(ai)")
            } else {
                phase = .pairing
                status = paired.note
            }
        } catch {
            phase = .failed
            status = error.localizedDescription
            registration = wearable.registration
            if shouldSpeakSessionCut(error) {
                await speakAndLogFail(
                    note: error.localizedDescription,
                    sessionId: nil,
                    spokenLine: BobBridgeError.failSpokenLine(for: error)
                )
            }
        }
    }

    func talkToBob() async {
        if phase == .idle || phase == .failed || phase == .pairing {
            await bootstrap()
        }
        guard phase == .ready || phase == .ended else { return }

        do {
            status = "Starting DAT DeviceSession · device_path=\(devicePath.rawValue)"
            let id = try await wearable.startDeviceSession()
            sessionId = id
            syncWearableFields()
            phase = .listening
            status = listeningStatus
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

            // Mock demo still injects one utterance so the first proof logs without speech.
            // Real path waits for the phone mic (HFP is not wired).
            if usesMockDevice {
                await handleUtterance("What's next?", capture: .demoInjected)
            }
        } catch {
            phase = .failed
            status = error.localizedDescription
            if shouldSpeakSessionCut(error) {
                await speakAndLogFail(
                    note: error.localizedDescription,
                    sessionId: sessionId,
                    spokenLine: BobBridgeError.failSpokenLine(for: error)
                )
            }
        }
    }

    func endSession() async {
        recognizer.stop()
        wearable.stopDeviceSession()
        syncWearableFields()
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

    private var listeningStatus: String {
        "Listening · stt_source=phone_mic · hfp=not_wired · meta_ai=\(metaAIUsed ? "used" : "none")"
    }

    private func readyStatus(_ paired: PairedGlasses) -> String {
        if usesMockDevice {
            return "Paired \(paired.deviceType) · \(paired.note)"
        }
        return "Selected \(paired.deviceType) · Meta AI registered · \(paired.note)"
    }

    private func syncWearableFields() {
        registration = wearable.registration
        sessionState = wearable.sessionState
        if phase == .pairing, wearable.isReadyToStartSession {
            phase = .ready
            status = "Selected \(HardwareContext.deviceTypeLogValue) · registration \(registration)"
        }
    }

    private func shouldSpeakSessionCut(_ error: Error) -> Bool {
        guard let wearableError = error as? WearableSessionError else { return true }
        switch wearableError {
        case .registrationFailed, .noMetaGlasses, .datUnavailable, .notPaired, .mockKitUnavailable:
            return false
        case .pairFailed, .sessionFailed:
            return true
        }
    }

    private func handleUtterance(_ text: String, capture: STTCapture) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let sessionId else { return }

        lastUtterance = trimmed
        phase = .thinking
        status = "BobBridge · stt_source=phone_mic · hfp=not_wired · \(capture.rawValue)"

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
                note: "utterance=\(trimmed) hfp_not_wired"
            )
            phase = .listening
            status = listeningStatus
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
            metaAIUsed: metaAIUsed,
            devicePath: devicePath,
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
