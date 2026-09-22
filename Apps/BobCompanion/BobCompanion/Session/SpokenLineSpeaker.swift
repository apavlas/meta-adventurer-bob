import AVFoundation
import Foundation

/// Speaks one line and returns when playback finishes.
///
/// Capture must not run during this call. `AVSpeechSynthesizer` and the
/// recognition engine share `AVAudioSession`; overlapping them is what left
/// HFP capture without a SpeechKit final.
@MainActor
final class SpokenLineSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechFinishDelegate()
    private let audioSession: GlassesAudioSession
    private var pendingUtterance: AVSpeechUtterance?
    private var pendingContinuation: CheckedContinuation<Void, Never>?

    init(audioSession: GlassesAudioSession) {
        self.audioSession = audioSession
        synthesizer.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] utterance in
            Task { @MainActor in
                self?.finish(utterance)
            }
        }
    }

    func speak(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pendingContinuation != nil {
            cancelCurrentWait()
            // stopSpeaking is queued. Give it a beat so it does not cancel the next line.
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        prepareSession()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let budget = speakBudget(for: trimmed)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingUtterance = utterance
            pendingContinuation = continuation
            synthesizer.speak(utterance)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                self.finish(utterance)
            }
        }
    }

    func stop() {
        cancelCurrentWait()
    }

    private func prepareSession() {
        do {
            try audioSession.configurePlayback()
        } catch {
            print("[Audio] playback session failed \(error.localizedDescription)")
        }
    }

    private func speakBudget(for line: String) -> TimeInterval {
        let words = max(line.split { $0.isWhitespace }.count, 1)
        return min(12, max(3, Double(words) * 0.7 + 1.5))
    }

    private func cancelCurrentWait() {
        let current = pendingContinuation
        pendingContinuation = nil
        pendingUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        current?.resume()
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        guard let pendingUtterance, pendingUtterance === utterance else { return }
        let current = pendingContinuation
        pendingContinuation = nil
        self.pendingUtterance = nil
        current?.resume()
    }
}

private final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: ((AVSpeechUtterance) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?(utterance)
    }
}
