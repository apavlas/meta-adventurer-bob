import AVFoundation
import BobCore
import Foundation
import Speech

/// Speech recognition from the active input route.
///
/// The tap is installed only after the preferred HFP input has settled, and only
/// once playback of our own line has stopped. `isFinal` is not guaranteed on
/// Adventurer HFP, so a stable partial calls `endAudio()` and, if that still
/// does not finalize, becomes the utterance. The BobBridge tag is chosen from
/// the route at delivery time.
@MainActor
final class PhoneMicRecognizer {
    private let audioEngine = AVAudioEngine()
    private let audioSession: GlassesAudioSession
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var onFinalUtterance: ((String, AudioInputDecision) -> Void)?
    private var onNoFinal: (() -> Void)?
    private var wantsRunning = false
    private var generation = 0
    private var deliveredFinal = false
    private var deliveredNoFinal = false
    private var rapidRestarts = 0
    private var lastRestart = Date.distantPast
    private var rebindAttempts = 0
    private var routeRebinds = 0
    private var configObserver: NSObjectProtocol?
    private var forceServerRecognition = false
    private var lastTaskUsedOnDevice = false
    private var listenArmedAt: Date?
    private var latestPartial = ""
    private var lastPartialAt: Date?
    private var endAudioAt: Date?
    private var silenceTask: Task<Void, Never>?
    private var noFinalTask: Task<Void, Never>?
    private var installedSampleRate: Double = 0
    private var installedChannels: AVAudioChannelCount = 0

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

    func start(
        onFinalUtterance: @escaping (String, AudioInputDecision) -> Void,
        onNoFinal: (() -> Void)? = nil
    ) async throws {
        stop()
        guard let recognizer, recognizer.isAvailable else {
            throw PhoneMicError.recognizerUnavailable
        }
        let generation = self.generation
        self.onFinalUtterance = onFinalUtterance
        self.onNoFinal = onNoFinal
        wantsRunning = true
        deliveredFinal = false
        deliveredNoFinal = false
        rapidRestarts = 0
        rebindAttempts = 0
        routeRebinds = 0
        forceServerRecognition = false
        latestPartial = ""
        lastPartialAt = nil
        endAudioAt = nil
        listenArmedAt = nil

        _ = try await audioSession.prepareForCapture()
        guard wantsRunning, generation == self.generation else { return }
        _ = await audioSession.waitForHandsFreeRoute()
        guard wantsRunning, generation == self.generation else { return }
        let settle = UInt64(LiveListenPolicy.postRouteSettle * 1_000_000_000)
        try? await Task.sleep(nanoseconds: settle)
        guard wantsRunning, generation == self.generation else { return }

        // `beginRecognitionTask` bumps `generation`. The awaits are already done.
        beginRecognitionTask(using: recognizer)
        observeEngineConfiguration()
        do {
            try installTapAndStartEngine()
        } catch {
            print("[Audio] engine start failed \(error.localizedDescription)")
            tearDownEngine()
        }
        guard wantsRunning else { return }
        listenArmedAt = Date()
        armNoFinalTimer()
        let decision = audioSession.currentDecision()
        print("[Audio] listening armed \(decision.statusFragment)")
    }

    func stop() {
        wantsRunning = false
        generation += 1
        onFinalUtterance = nil
        onNoFinal = nil
        cancelTimers()
        tearDownEngine()
        endRecognition()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// Restart the tap after a route change. A format change also restarts the
    /// speech request so one task never mixes sample rates.
    func rebindInputIfNeeded() {
        guard wantsRunning, !deliveredFinal, !deliveredNoFinal, request != nil else { return }
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            scheduleRebind()
            return
        }
        let sameFormat = audioEngine.isRunning
            && abs(format.sampleRate - installedSampleRate) < 1
            && format.channelCount == installedChannels
        guard !sameFormat else { return }
        restartListening(reason: "route-rebind", countsAsError: false)
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
        request.taskHint = .dictation
        let decision = audioSession.currentDecision()
        let useOnDevice = !forceServerRecognition && LiveListenPolicy.allowsOnDeviceRecognition(
            sttSource: decision.sttSource,
            supportsOnDevice: recognizer.supportsOnDeviceRecognition
        )
        lastTaskUsedOnDevice = useOnDevice
        if useOnDevice {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        generation += 1
        let generation = generation
        print("[Audio] recognition task on_device=\(useOnDevice) \(decision.statusFragment)")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error, generation: generation)
            }
        }
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        generation: Int
    ) {
        guard generation == self.generation, wantsRunning, !deliveredFinal, !deliveredNoFinal else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if LiveListenPolicy.isOwnSpokenEcho(trimmed) {
                    print("[Audio] ignored echo")
                    restartListening(reason: "echo", countsAsError: true)
                    return
                }
                if !trimmed.isEmpty {
                    deliver(trimmed, reason: "speechkit-final")
                    return
                }
                if endAudioAt != nil, !latestPartial.isEmpty {
                    deliver(latestPartial, reason: "partial-after-empty-final")
                    return
                }
                restartListening(reason: "empty-final", countsAsError: true)
                return
            }
            if endAudioAt == nil {
                notePartial(text)
            }
        }
        if let error {
            let ns = error as NSError
            print("[Audio] recognition error domain=\(ns.domain) code=\(ns.code)")
            if endAudioAt != nil, !latestPartial.isEmpty {
                deliver(latestPartial, reason: "partial-after-error")
                return
            }
            if lastTaskUsedOnDevice {
                forceServerRecognition = true
                restartListening(reason: "on-device-error", countsAsError: true)
                return
            }
            restartListening(reason: "error", countsAsError: true)
        }
    }

    private func notePartial(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !LiveListenPolicy.isOwnSpokenEcho(text) else { return }
        latestPartial = text
        lastPartialAt = Date()
        silenceTask?.cancel()
        let silence = LiveListenPolicy.partialSilence
        silenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(silence * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.evaluate()
        }
    }

    private func armNoFinalTimer() {
        noFinalTask?.cancel()
        noFinalTask = Task { @MainActor in
            while !Task.isCancelled, self.wantsRunning, !self.deliveredFinal, !self.deliveredNoFinal {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        guard wantsRunning, !deliveredFinal, !deliveredNoFinal else { return }
        let start = listenArmedAt ?? Date()
        let elapsed = Date().timeIntervalSince(start)
        let silence: TimeInterval?
        if latestPartial.isEmpty || lastPartialAt == nil {
            silence = nil
        } else {
            silence = Date().timeIntervalSince(lastPartialAt ?? start)
        }
        let endAt = endAudioAt.map { $0.timeIntervalSince(start) }
        apply(LiveListenPolicy.decide(
            elapsedSinceListenStart: elapsed,
            partial: latestPartial,
            silence: silence,
            endAudioAt: endAt
        ))
    }

    private func apply(_ action: LiveListenPolicy.Action) {
        switch action {
        case .wait:
            break
        case .endAudio:
            guard endAudioAt == nil, wantsRunning, !deliveredFinal else { return }
            endAudioAt = Date()
            silenceTask?.cancel()
            tearDownEngine()
            print("[Audio] endAudio reason=partial-silence chars=\(latestPartial.count)")
            request?.endAudio()
            let grace = LiveListenPolicy.finalGrace
            silenceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.evaluate()
            }
        case .promotePartial(let text):
            deliver(text, reason: "partial-promoted")
        case .missedPrompt:
            fireNoFinal()
        }
    }

    /// Stop capture before the caller speaks, so the reply is not transcribed.
    private func deliver(_ text: String, reason: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wantsRunning, !deliveredFinal, !trimmed.isEmpty else { return }
        if LiveListenPolicy.isOwnSpokenEcho(trimmed) {
            print("[Audio] ignored echo")
            restartListening(reason: "echo", countsAsError: true)
            return
        }
        deliveredFinal = true
        wantsRunning = false
        cancelTimers()
        generation += 1
        let decision = audioSession.currentDecision()
        tearDownEngine()
        endRecognition()
        print("[Audio] utterance reason=\(reason) chars=\(trimmed.count) \(decision.statusFragment)")
        onFinalUtterance?(trimmed, decision)
    }

    private func fireNoFinal() {
        guard wantsRunning, !deliveredFinal, !deliveredNoFinal else { return }
        deliveredNoFinal = true
        wantsRunning = false
        cancelTimers()
        generation += 1
        tearDownEngine()
        endRecognition()
        let callback = onNoFinal
        onFinalUtterance = nil
        onNoFinal = nil
        print("[Audio] speechkit_no_final timeout_s=\(Int(LiveListenPolicy.noFinalTimeout)) action=retry_prompt")
        callback?()
    }

    /// Keep capture up across route blips before a phrase is finalized.
    /// A tight burst of failures leaves the no-final timer in place instead of spinning.
    private func restartListening(reason: String, countsAsError: Bool) {
        guard wantsRunning, !deliveredFinal, !deliveredNoFinal, let recognizer else { return }
        if countsAsError {
            let now = Date()
            if now.timeIntervalSince(lastRestart) < 0.4 {
                rapidRestarts += 1
            } else {
                rapidRestarts = 0
            }
            lastRestart = now
            if rapidRestarts >= 5 {
                print("[Audio] recognition paused after repeated errors")
                tearDownEngine()
                endRecognition()
                return
            }
        } else if reason == "route-rebind" {
            routeRebinds += 1
            if routeRebinds > 4 {
                print("[Audio] route rebind paused")
                return
            }
        }
        print("[Audio] recognition restarted reason=\(reason)")
        latestPartial = ""
        lastPartialAt = nil
        endAudioAt = nil
        silenceTask?.cancel()
        tearDownEngine()
        endRecognition()
        beginRecognitionTask(using: recognizer)
        do {
            try installTapAndStartEngine()
        } catch {
            print("[Audio] recognition restart failed \(error.localizedDescription)")
            tearDownEngine()
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
            installedSampleRate = 0
            installedChannels = 0
            scheduleRebind()
            return
        }
        rebindAttempts = 0
        installedSampleRate = format.sampleRate
        installedChannels = format.channelCount
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        print("[Audio] tap sample_rate=\(format.sampleRate) channels=\(format.channelCount)")
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

    private func cancelTimers() {
        silenceTask?.cancel()
        silenceTask = nil
        noFinalTask?.cancel()
        noFinalTask = nil
    }

    private func tearDownEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        installedSampleRate = 0
        installedChannels = 0
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
