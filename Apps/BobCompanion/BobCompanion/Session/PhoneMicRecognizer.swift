import AVFoundation
import BobCore
import Foundation
import Speech

/// Speech recognition from the active input route.
///
/// Real path (`allowsHFP`) asks iOS for the Bluetooth HFP/SCO input. The BobBridge
/// tag is chosen later from the current route, not assumed here.
/// Mock path keeps the iPhone microphone and does not set `.allowBluetooth`.
@MainActor
final class PhoneMicRecognizer {
    private let audioEngine = AVAudioEngine()
    private let audioSession: GlassesAudioSession
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var onFinalUtterance: ((String, AudioInputDecision) -> Void)?
    private var wantsRunning = false
    private var generation = 0
    private var deliveredFinal = false
    private var rapidRestarts = 0
    private var lastRestart = Date.distantPast
    private var rebindAttempts = 0
    private var configObserver: NSObjectProtocol?

    var isRunning: Bool { audioEngine.isRunning }

    init(audioSession: GlassesAudioSession) {
        self.audioSession = audioSession
    }

    func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }

        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(onFinalUtterance: @escaping (String, AudioInputDecision) -> Void) async throws {
        stop()
        guard let recognizer, recognizer.isAvailable else {
            throw PhoneMicError.recognizerUnavailable
        }
        self.onFinalUtterance = onFinalUtterance
        _ = try await audioSession.prepareForCapture()
        wantsRunning = true
        deliveredFinal = false
        rapidRestarts = 0
        rebindAttempts = 0
        beginRecognitionTask(using: recognizer)
        observeEngineConfiguration()
        do {
            try installTapAndStartEngine()
        } catch {
            stop()
            throw error
        }
        _ = await audioSession.waitForHandsFreeRoute()
    }

    func stop() {
        wantsRunning = false
        generation += 1
        onFinalUtterance = nil
        tearDownEngine()
        endRecognition()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// Restart the tap after a route change stopped the engine. No-op while capture is healthy.
    func rebindInputIfNeeded() {
        guard wantsRunning, request != nil else { return }
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            scheduleRebind()
            return
        }
        guard !audioEngine.isRunning else { return }
        do {
            try installTapAndStartEngine()
        } catch {
            print("[Audio] rebind failed \(error.localizedDescription)")
        }
    }

    private func observeEngineConfiguration() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebindInputIfNeeded()
            }
        }
    }

    private func beginRecognitionTask(using recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        generation += 1
        let generation = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.generation, self.wantsRunning else { return }
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.deliveredFinal = true
                        let decision = self.audioSession.currentDecision()
                        self.onFinalUtterance?(text, decision)
                        return
                    }
                    self.restartListening(reason: "empty-final")
                    return
                }
                if error != nil {
                    if self.deliveredFinal {
                        self.finishAfterUtterance()
                    } else {
                        self.restartListening(reason: "error")
                    }
                }
            }
        }
    }

    /// The speech task ends after a phrase. Stop the engine so the spoken reply is not captured.
    private func finishAfterUtterance() {
        wantsRunning = false
        tearDownEngine()
        endRecognition()
    }

    /// Keep capture up across route blips before a phrase is finalized.
    /// A tight burst of failures stops capture instead of spinning.
    private func restartListening(reason: String) {
        guard wantsRunning, let recognizer else { return }
        let now = Date()
        if now.timeIntervalSince(lastRestart) < 0.4 {
            rapidRestarts += 1
        } else {
            rapidRestarts = 0
        }
        lastRestart = now
        guard rapidRestarts < 5 else {
            print("[Audio] recognition stopped after repeated errors")
            stop()
            return
        }
        print("[Audio] recognition restarted reason=\(reason)")
        deliveredFinal = false
        endRecognition()
        beginRecognitionTask(using: recognizer)
        do {
            try installTapAndStartEngine()
        } catch {
            print("[Audio] recognition restart failed \(error.localizedDescription)")
            stop()
        }
    }

    private func installTapAndStartEngine() throws {
        guard let request else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            scheduleRebind()
            return
        }
        rebindAttempts = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func scheduleRebind() {
        rebindAttempts += 1
        guard wantsRunning, rebindAttempts <= 8 else {
            print("[Audio] input format stayed unusable")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.rebindInputIfNeeded()
        }
    }

    private func tearDownEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func endRecognition() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}

enum PhoneMicError: Error {
    case recognizerUnavailable
}
