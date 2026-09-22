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
    @Published private(set) var inputDecision: AudioInputDecision

    let usesMockDevice: Bool
    let devicePath: DevicePathKind

    private let wearable: any WearableSessionControlling
    private let audioSession: GlassesAudioSession
    private let recognizer: PhoneMicRecognizer
    private let speaker: SpokenLineSpeaker
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
        let audioSession = GlassesAudioSession(allowsHFP: !path.useMockDevice)
        self.audioSession = audioSession
        recognizer = PhoneMicRecognizer(audioSession: audioSession)
        speaker = SpokenLineSpeaker(audioSession: audioSession)
        inputDecision = AudioInputClassifier.decide(inputs: [], allowsHFP: !path.useMockDevice)
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
        audioSession.onDecision = { [weak self] decision in
            self?.applyInputDecision(decision)
            self?.recognizer.rebindInputIfNeeded()
        }
    }

    var isListening: Bool { phase == .listening || phase == .thinking }

    var metaAIUsed: Bool { wearable.metaAIUsed }

    /// Honest capture tag. `hfp` only after the real path sees an HFP/SCO input.
    var sttSummary: String {
        let mic = liveSTTAvailable ? "live" : "mic not granted"
        let ai = metaAIUsed ? "used" : "none"
        if usesMockDevice {
            return "stt_source=phone_mic (\(mic)) · hfp=not_wired · meta_ai=\(ai)"
        }
        return "\(inputDecision.statusFragment) (\(mic)) · meta_ai=\(ai)"
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
            audioSession.startObserving()
            liveSTTAvailable = await recognizer.requestAccess()
            if liveSTTAvailable, !usesMockDevice {
                do {
                    let prepared = try await audioSession.prepareForCapture()
                    applyInputDecision(prepared)
                } catch {
                    print("[Audio] prepare failed \(error.localizedDescription)")
                }
            }
            status = listeningStatus
            await speakAndLog(
                path: .start,
                role: .open,
                line: GoldenSpokenLine.start,
                sessionId: id,
                sttSource: nil,
                sttCapture: nil,
                hfpState: measuredRoute.hfpState,
                audioRoute: measuredRoute.audioRoute,
                note: "CTA \(LexCopy.talkToBob)"
            )

            if liveSTTAvailable {
                do {
                    try await recognizer.start { [weak self] text, decision in
                        Task { await self?.handleUtterance(text, capture: .live, route: decision) }
                    }
                } catch {
                    liveSTTAvailable = false
                    print("[Audio] recognizer start failed \(error.localizedDescription)")
                }
            }
            if !usesMockDevice {
                applyInputDecision(audioSession.currentDecision())
            }
            status = listeningStatus

            // Mock demo still injects one utterance so the first proof logs without speech.
            // Real path waits for the live route and tags hfp only when that input is HFP.
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
        audioSession.stopObserving()
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
            hfpState: measuredRoute.hfpState,
            audioRoute: measuredRoute.audioRoute,
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

    /// Real path logs the measured route. Mock stays phone_mic and does not pretend to read HFP.
    private var measuredRoute: (hfpState: HFPRouteState?, audioRoute: String?) {
        guard !usesMockDevice else { return (nil, nil) }
        return (inputDecision.hfpState, inputDecision.loggedRoute)
    }

    private var listeningStatus: String {
        let ai = metaAIUsed ? "used" : "none"
        if usesMockDevice {
            return "Listening · stt_source=phone_mic · hfp=not_wired · meta_ai=\(ai)"
        }
        return "Listening · \(inputDecision.statusFragment) · meta_ai=\(ai)"
    }

    private func applyInputDecision(_ decision: AudioInputDecision) {
        inputDecision = decision
        if phase == .listening {
            status = listeningStatus
        }
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

    private func handleUtterance(_ text: String, capture: STTCapture, route: AudioInputDecision? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let sessionId else { return }

        lastUtterance = trimmed
        phase = .thinking

        let liveRoute = capture == .live && !usesMockDevice
        let decision = liveRoute ? (route ?? audioSession.currentDecision()) : nil
        if let decision {
            applyInputDecision(decision)
        }
        let source: STTSource = decision?.sttSource ?? .phoneMic
        let hfpState: HFPRouteState? = decision?.hfpState ?? .notWired
        let audioRoute = decision?.loggedRoute
        let routeNote: String
        if let decision {
            let wired = decision.hfpState == .wired ? "hfp_wired" : "hfp_not_wired"
            routeNote = "utterance=\(trimmed) \(wired) route=\(decision.audioRoute)"
        } else if capture == .demoInjected && !usesMockDevice {
            routeNote = "utterance=\(trimmed) demo_injected hfp_not_wired"
        } else {
            routeNote = "utterance=\(trimmed) hfp_not_wired"
        }
        status = "BobBridge · stt_source=\(source.rawValue) · hfp=\(hfpState?.rawValue ?? HFPRouteState.notWired.rawValue) · \(capture.rawValue)"

        do {
            let request = BobBridgeRequest(
                utterance: trimmed,
                sttSource: source,
                sessionId: sessionId
            )
            let response = try await bob.complete(request)
            let path: GoldenPath = response.spokenLine == GoldenSpokenLine.overBudget ? .overBudget : .reply
            await speakAndLog(
                path: path,
                role: .reply,
                line: response.spokenLine,
                sessionId: sessionId,
                sttSource: source,
                sttCapture: capture,
                deskFull: response.deskFull,
                hfpState: hfpState,
                audioRoute: audioRoute,
                note: routeNote
            )
            phase = .listening
            status = listeningStatus
        } catch {
            phase = .failed
            recognizer.stop()
            audioSession.stopObserving()
            wearable.stopDeviceSession()
            await speakAndLogFail(
                note: String(describing: error),
                sessionId: sessionId,
                spokenLine: BobBridgeError.failSpokenLine(for: error),
                sttSource: source,
                hfpState: hfpState,
                audioRoute: audioRoute
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
        hfpState: HFPRouteState? = nil,
        audioRoute: String? = nil,
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
            hfpState: hfpState,
            audioRoute: audioRoute,
            note: note
        )
        log.append(entry)
    }

    private func speakAndLogFail(
        note: String,
        sessionId: String?,
        spokenLine: String = GoldenSpokenLine.fail,
        sttSource: STTSource = .phoneMic,
        hfpState: HFPRouteState? = nil,
        audioRoute: String? = nil
    ) async {
        status = note
        await speakAndLog(
            path: .fail,
            role: .fail,
            line: spokenLine,
            sessionId: sessionId,
            sttSource: sttSource,
            sttCapture: nil,
            hfpState: hfpState,
            audioRoute: audioRoute,
            note: note
        )
    }
}
