import AVFoundation
import BobCore
import Foundation
import Speech

/// Speech recognition from the active input route.
///
/// On the real path the tap is installed only after the engine is running, so the
/// format is the live HFP bus and not the 48 kHz rate left by TTS. Voice processing
/// is enabled there because `.voiceChat` delivers SCO to VoiceProcessingIO; a
/// Remote I/O tap on that route stays at zero and SpeechKit never emits a partial.
/// `isFinal` is not guaranteed on Adventurer HFP, so a stable partial calls
/// `endAudio()` and, if that still does not finalize, becomes the utterance.
/// The BobBridge tag is chosen from the route at delivery time.
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
    private var tapLogTask: Task<Void, Never>?
    private var formatRecheck: Task<Void, Never>?
    private var installedSampleRate: Double = 0
    private var installedChannels: AVAudioChannelCount = 0
    private var voiceProcessingOn = false
    private var partialEvents = 0
    private var lastLoggedPartial = ""
    private let tapMeter = TapMeter()
    private let monoConverter = MonoTapConverter()

    var isRunning: Bool { audioEngine.isRunning }

    init(audioSession: GlassesAudioSession) {
        self.audioSession = audioSession
    }

    /// Latest tap evidence for this listen window. Safe to read after `stop`.
    func captureSummary() -> CaptureEnergySummary {
        var summary = tapMeter.snapshot()
        summary.partialEvents = partialEvents
        return summary
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
        partialEvents = 0
        lastLoggedPartial = ""
        tapMeter.reset()

        audioSession.releaseSynthesizerRoute()
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
            noteRecognitionEvent(text: text, isFinal: result.isFinal)
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

    private func noteRecognitionEvent(text: String, isFinal: Bool) {
        partialEvents += 1
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastLoggedPartial || isFinal else { return }
        lastLoggedPartial = trimmed
        print(HFPCaptureGraph.partialLogLine(chars: trimmed.count, isFinal: isFinal))
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
        let summary = captureSummary()
        tearDownEngine()
        endRecognition()
        let callback = onNoFinal
        onFinalUtterance = nil
        onNoFinal = nil
        print("[Audio] speechkit_no_final timeout_s=\(Int(LiveListenPolicy.noFinalTimeout)) \(summary.logFragment) action=retry_prompt")
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
        lastLoggedPartial = ""
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
        tapLogTask?.cancel()
        tapLogTask = nil
        if audioSession.allowsHFP {
            try installHandsFreeTap(request: request)
        } else {
            try installDirectTap(request: request)
        }
    }

    /// Mock / phone path. Install from the current output format, then start.
    private func installDirectTap(request: SFSpeechAudioBufferRecognitionRequest) throws {
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
        tapMeter.noteFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        installConsumeTap(on: input, format: format, request: request)
        audioEngine.prepare()
        try audioEngine.start()
        print("[Audio] tap sample_rate=\(format.sampleRate) channels=\(format.channelCount) voice_processing=off")
        armTapDiagnostics()
    }

    /// Real path. Start the engine first so the tap format is the running HFP bus,
    /// and enable voice processing so SCO is attached to this engine.
    private func installHandsFreeTap(request: SFSpeechAudioBufferRecognitionRequest) throws {
        stopEngineForRetarget()
        let voiceProcessing = enableVoiceProcessingIfNeeded()
        try startEngineIfNeeded()

        var hardware = audioEngine.inputNode.inputFormat(forBus: 0)
        var output = audioEngine.inputNode.outputFormat(forBus: 0)
        if HFPCaptureGraph.shouldForceHardwareFormat(
            outputRate: output.sampleRate,
            outputChannels: Int(output.channelCount),
            hardwareRate: hardware.sampleRate,
            hardwareChannels: Int(hardware.channelCount)
        ) {
            print("[Audio] tap format mismatch hardware_rate=\(hardware.sampleRate) hardware_channels=\(hardware.channelCount) output_rate=\(output.sampleRate) output_channels=\(output.channelCount)")
            stopEngineForRetarget()
            do {
                try audioSession.reassertHandsFreeInput()
                try AVAudioSession.sharedInstance().setPreferredSampleRate(HFPCaptureGraph.preferredSampleRate)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("[Audio] format renegotiate failed \(error.localizedDescription)")
            }
            try startEngineIfNeeded()
            hardware = audioEngine.inputNode.inputFormat(forBus: 0)
            output = audioEngine.inputNode.outputFormat(forBus: 0)
        }

        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        print(HFPCaptureGraph.formatLogLine(
            sessionRate: sessionRate,
            hardwareRate: hardware.sampleRate,
            hardwareChannels: Int(hardware.channelCount),
            outputRate: output.sampleRate,
            outputChannels: Int(output.channelCount),
            voiceProcessing: voiceProcessing
        ))

        guard let tapFormat = usableOutputFormat(output) else {
            installedSampleRate = 0
            installedChannels = 0
            stopEngineForRetarget()
            scheduleRebind()
            return
        }

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        rebindAttempts = 0
        installedSampleRate = tapFormat.sampleRate
        installedChannels = tapFormat.channelCount
        tapMeter.noteFormat(sampleRate: tapFormat.sampleRate, channels: Int(tapFormat.channelCount))
        installConsumeTap(on: input, format: tapFormat, request: request)
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        print("[Audio] tap sample_rate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount) voice_processing=\(voiceProcessing ? "on" : "off")")
        armTapDiagnostics()
        scheduleFormatRecheck()
    }

    /// The tap format has to be the running output bus. A hardware-only format
    /// installed on a 0 Hz bus does not receive SCO samples.
    private func usableOutputFormat(_ output: AVAudioFormat) -> AVAudioFormat? {
        guard output.sampleRate > 0, output.channelCount > 0 else { return nil }
        return output
    }

    private func installConsumeTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        let meter = tapMeter
        let converter = monoConverter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let reading = TapPCM.measure(buffer)
            let first = meter.record(
                rms: reading.rms,
                peak: reading.peak,
                sampleRate: buffer.format.sampleRate,
                channels: Int(buffer.format.channelCount)
            )
            request.append(converter.appendBuffer(from: buffer))
            if first {
                let line = HFPCaptureGraph.firstBufferLogLine(summary: meter.snapshot())
                DispatchQueue.main.async {
                    print(line)
                }
            }
        }
    }

    private func enableVoiceProcessingIfNeeded() -> Bool {
        guard HFPCaptureGraph.shouldEnableVoiceProcessing(allowsHFP: audioSession.allowsHFP) else {
            return false
        }
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
            audioEngine.inputNode.isVoiceProcessingAGCEnabled = true
            audioEngine.inputNode.isVoiceProcessingBypassed = false
            voiceProcessingOn = true
            return true
        } catch {
            if voiceProcessingOn { return true }
            print("[Audio] voice_processing=off error=\(error.localizedDescription)")
            return false
        }
    }

    private func startEngineIfNeeded() throws {
        if audioEngine.isRunning { return }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopEngineForRetarget() {
        let input = audioEngine.inputNode
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        input.removeTap(onBus: 0)
    }

    private func scheduleFormatRecheck() {
        formatRecheck?.cancel()
        let generation = generation
        formatRecheck = Task { @MainActor in
            let settle = UInt64(HFPCaptureGraph.scoFormatSettle * 1_000_000_000)
            try? await Task.sleep(nanoseconds: settle)
            guard !Task.isCancelled, self.wantsRunning, generation == self.generation else { return }
            self.rebindInputIfNeeded()
        }
    }

    private func armTapDiagnostics() {
        tapLogTask?.cancel()
        tapLogTask = Task { @MainActor in
            let started = Date()
            while !Task.isCancelled, self.wantsRunning {
                let interval = UInt64(HFPCaptureGraph.tapLogInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, self.wantsRunning else { return }
                let elapsed = Date().timeIntervalSince(started)
                let summary = self.captureSummary()
                print(HFPCaptureGraph.tapEnergyLogLine(seconds: elapsed, summary: summary))
                if elapsed + 0.05 >= HFPCaptureGraph.tapLogWindow {
                    let audible = HFPCaptureGraph.hasAudibleEnergy(
                        peak: summary.peak,
                        bufferCount: summary.bufferCount
                    )
                    print(HFPCaptureGraph.tapEnergySummaryLogLine(audible: audible, summary: summary))
                    return
                }
            }
        }
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
        tapLogTask?.cancel()
        tapLogTask = nil
        formatRecheck?.cancel()
        formatRecheck = nil
    }

    private func tearDownEngine() {
        stopEngineForRetarget()
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

/// RMS/peak of one tap buffer. Float taps are the AVAudioEngine case.
enum TapPCM {
    static func measure(_ buffer: AVAudioPCMBuffer) -> LevelReading {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else {
            return LevelReading(rms: 0, peak: 0)
        }
        var best = LevelReading(rms: 0, peak: 0)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return best }
        for index in 0 ..< channelCount {
            let pointer = UnsafeBufferPointer(start: channels[index], count: frames)
            best = HFPCaptureGraph.louder(best, HFPCaptureGraph.measure(pointer))
        }
        return best
    }
}

/// SpeechKit treats a stereo HFP buffer as empty when only one channel has SCO audio.
/// The tap callback is serial, so this converter is only touched there.
final class MonoTapConverter: @unchecked Sendable {
    private var mono: AVAudioPCMBuffer?

    func appendBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1,
              let source = buffer.floatChannelData,
              buffer.frameLength > 0,
              let mono = monoBuffer(matching: buffer)
        else {
            return buffer
        }
        guard let destination = mono.floatChannelData else { return buffer }
        let frames = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        let scale = 1 / Float(channels)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channels {
                sum += source[channel][frame]
            }
            destination[0][frame] = sum * scale
        }
        return mono
    }

    private func monoBuffer(matching buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if let mono,
           mono.frameCapacity >= buffer.frameLength,
           mono.format.sampleRate == buffer.format.sampleRate {
            return mono
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let created = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        mono = created
        return created
    }
}

/// Lock-protected tap counters. The audio thread records; the main actor reads.
final class TapMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0
    private var rms: Float = 0
    private var peak: Float = 0
    private var sampleRate: Double = 0
    private var channels = 0

    func reset() {
        lock.lock()
        bufferCount = 0
        rms = 0
        peak = 0
        sampleRate = 0
        channels = 0
        lock.unlock()
    }

    func noteFormat(sampleRate: Double, channels: Int) {
        lock.lock()
        self.sampleRate = sampleRate
        self.channels = channels
        lock.unlock()
    }

    /// Returns true for the first buffer after `reset`.
    func record(rms: Float, peak: Float, sampleRate: Double, channels: Int) -> Bool {
        lock.lock()
        bufferCount += 1
        let first = bufferCount == 1
        self.rms = rms
        if peak > self.peak { self.peak = peak }
        if sampleRate > 0 { self.sampleRate = sampleRate }
        if channels > 0 { self.channels = channels }
        lock.unlock()
        return first
    }

    func snapshot() -> CaptureEnergySummary {
        lock.lock()
        defer { lock.unlock() }
        return CaptureEnergySummary(
            bufferCount: bufferCount,
            peak: peak,
            rms: rms,
            sampleRate: sampleRate,
            channels: channels,
            partialEvents: 0
        )
    }
}
