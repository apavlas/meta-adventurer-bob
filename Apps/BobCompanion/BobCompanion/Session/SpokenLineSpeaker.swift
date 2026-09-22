import AVFoundation
import Foundation

@MainActor
final class SpokenLineSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession: GlassesAudioSession

    init(audioSession: GlassesAudioSession) {
        self.audioSession = audioSession
    }

    func speak(_ line: String) {
        prepareSession()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func prepareSession() {
        do {
            try audioSession.configurePlayback()
        } catch {
            print("[Audio] playback session failed \(error.localizedDescription)")
        }
    }
}
