import AVFoundation
import BobCore
import Foundation

/// Real-path capture session for Adventurer HFP/SCO.
///
/// Meta DAT does not capture the glasses microphone. The documented route is
/// `playAndRecord` plus the Bluetooth HFP option (`.allowBluetooth` on the iOS 16 SDK;
/// newer SDKs name it `.allowBluetoothHFP`), then `setPreferredInput` on `BluetoothHFP`.
/// A2DP does not provide a mic. `.defaultToSpeaker` is omitted here because forcing the
/// phone speaker also keeps the built-in microphone.
///
/// After TTS, the route can already say `BluetoothHFP` while the SCO uplink is still
/// the playback graph. Capture prefers 16 kHz mono, re-asserts the HFP input, and
/// reactivates the session so the engine's tap is not installed on an empty converter.
@MainActor
final class GlassesAudioSession {
    let allowsHFP: Bool
    var onDecision: ((AudioInputDecision) -> Void)?

    private var routeObserver: NSObjectProtocol?
    private var lastLogged: String?

    init(allowsHFP: Bool) {
        self.allowsHFP = allowsHFP
    }

    /// Drop the synthesizer's hold on SCO. Call this only after a spoken line has
    /// finished. Doing it before the open line can drop `hfp=wired` off the START card.
    func releaseSynthesizerRoute() {
        guard allowsHFP else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func prepareForCapture() async throws -> AudioInputDecision {
        _ = try configureCapture()
        guard allowsHFP else { return currentDecision() }
        do {
            try reassertHandsFreeInput()
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[Audio] hfp reassert failed \(error.localizedDescription)")
        }
        let settled = currentDecision()
        publish(settled)
        return settled
    }

    /// Meta: after the audio engine starts, the HFP route needs a moment before `currentRoute` shows the glasses mic.
    func waitForHandsFreeRoute() async -> AudioInputDecision {
        let initial = currentDecision()
        guard allowsHFP, initial.hfpState != .wired, hasAvailableHFPInput() else {
            return initial
        }
        for _ in 0 ..< 8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try? preferHandsFreeInputIfAllowed()
            let settled = currentDecision()
            if settled.hfpState == .wired {
                publish(settled)
                return settled
            }
        }
        let settled = currentDecision()
        publish(settled)
        return settled
    }

    @discardableResult
    func configureCapture() throws -> AudioInputDecision {
        if allowsHFP {
            try apply(mode: .voiceChat, options: .allowBluetooth)
            logAvailableInputs()
            try preferHandsFreeInputIfAllowed()
        } else {
            try apply(mode: .measurement, options: [.defaultToSpeaker])
        }
        let decision = currentDecision()
        publish(decision)
        return decision
    }

    @discardableResult
    func configurePlayback() throws -> AudioInputDecision {
        if allowsHFP {
            try apply(mode: .voiceChat, options: .allowBluetooth)
            try preferHandsFreeInputIfAllowed()
        } else {
            try apply(mode: .spokenAudio, options: [.defaultToSpeaker])
        }
        let decision = currentDecision()
        publish(decision)
        return decision
    }

    func currentDecision() -> AudioInputDecision {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map {
            AudioInputPort(portType: $0.portType.rawValue, portName: $0.portName)
        }
        return AudioInputClassifier.decide(inputs: inputs, allowsHFP: allowsHFP)
    }

    func preferHandsFreeInputIfAllowed() throws {
        guard allowsHFP else { return }
        let session = AVAudioSession.sharedInstance()
        let available = session.availableInputs ?? []
        let ports = available.map { AudioInputPort(portType: $0.portType.rawValue, portName: $0.portName) }
        guard let index = AudioInputClassifier.preferredHFPIndex(in: ports) else { return }
        let chosen = available[index]
        if session.currentRoute.inputs.contains(where: { $0.uid == chosen.uid }) { return }
        if session.preferredInput?.uid == chosen.uid { return }
        try session.setPreferredInput(chosen)
        let token = AudioInputClassifier.routeToken(portType: ports[index].portType, portName: ports[index].portName)
        print("[Audio] preferred_input=\(token)")
    }

    /// Call `setPreferredInput` again at capture start. The route can already be HFP
    /// after TTS while the record direction of SCO is not attached to this session.
    func reassertHandsFreeInput() throws {
        guard allowsHFP else { return }
        let session = AVAudioSession.sharedInstance()
        let available = session.availableInputs ?? []
        let ports = available.map { AudioInputPort(portType: $0.portType.rawValue, portName: $0.portName) }
        guard let index = AudioInputClassifier.preferredHFPIndex(in: ports) else { return }
        try session.setPreferredInput(available[index])
        let token = AudioInputClassifier.routeToken(portType: ports[index].portType, portName: ports[index].portName)
        print("[Audio] reassert_input=\(token)")
    }

    func startObserving() {
        stopObserving()
        let session = AVAudioSession.sharedInstance()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleRouteChange()
            }
        }
    }

    func stopObserving() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
    }

    private func handleRouteChange() {
        if allowsHFP {
            try? preferHandsFreeInputIfAllowed()
        }
        publish(currentDecision())
    }

    private func apply(mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: mode, options: options)
        if allowsHFP {
            do {
                try session.setPreferredSampleRate(HFPCaptureGraph.preferredSampleRate)
                try session.setPreferredIOBufferDuration(HFPCaptureGraph.preferredIOBufferDuration)
            } catch {
                print("[Audio] preferred_rate failed \(error.localizedDescription)")
            }
            // Mono matches SCO. A stereo bus here is a tap that SpeechKit never finals.
            try? session.setPreferredInputNumberOfChannels(1)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func hasAvailableHFPInput() -> Bool {
        let available = AVAudioSession.sharedInstance().availableInputs ?? []
        let ports = available.map { AudioInputPort(portType: $0.portType.rawValue, portName: $0.portName) }
        return AudioInputClassifier.preferredHFPIndex(in: ports) != nil
    }

    private func logAvailableInputs() {
        let available = AVAudioSession.sharedInstance().availableInputs ?? []
        let ports = available.map { AudioInputPort(portType: $0.portType.rawValue, portName: $0.portName) }
        let listed = ports
            .map { AudioInputClassifier.routeToken(portType: $0.portType, portName: $0.portName) }
            .joined(separator: ",")
        let hfp = AudioInputClassifier.preferredHFPIndex(in: ports) == nil ? "absent" : "present"
        print("[Audio] available_inputs=\(listed.isEmpty ? "none" : listed) hfp=\(hfp)")
    }

    private func publish(_ decision: AudioInputDecision) {
        if decision.logLine != lastLogged {
            print(decision.logLine)
            lastLogged = decision.logLine
        }
        onDecision?(decision)
    }
}
