import Foundation

/// When live SpeechKit should endpoint, give up, or keep waiting.
///
/// Adventurer HFP can show `hfp=wired` while `SFSpeechRecognitionTask` never
/// sets `isFinal`. Partials often still arrive. The companion applies this
/// after the open line has finished speaking, so that line is not the utterance.
public enum LiveListenPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case wait
        /// Partial text has settled. Stop the tap and call `endAudio()` so SpeechKit can emit `isFinal`.
        case endAudio
        /// `endAudio()` did not produce `isFinal`. Use the partial. The route tag stays honest.
        case promotePartial(String)
        /// No transcript. Speak the retry line. This is not an STT result and must not be tagged `hfp`.
        case missedPrompt
    }

    /// No partial and no final after the listening window opens.
    public static let noFinalTimeout: TimeInterval = 5

    /// How long a partial must sit unchanged before we ask SpeechKit to finalize.
    public static let partialSilence: TimeInterval = 1

    /// How long to wait for `isFinal` after `endAudio()` before promoting the partial.
    public static let finalGrace: TimeInterval = 1

    /// Safety valve when partials never stop changing (HFP comfort noise).
    public static let maxListen: TimeInterval = 12

    /// Pause after playback returns so the HFP input format is the one the tap uses.
    public static let postRouteSettle: TimeInterval = 0.25

    /// On-device recognition accepts narrowband HFP buffers and then often never emits `isFinal`.
    /// Phone-mic capture can still require it when the recognizer supports it.
    public static func allowsOnDeviceRecognition(sttSource: STTSource, supportsOnDevice: Bool) -> Bool {
        supportsOnDevice && sttSource != .hfp
    }

    public static func decide(
        elapsedSinceListenStart: TimeInterval,
        partial: String,
        silence: TimeInterval?,
        endAudioAt: TimeInterval?
    ) -> Action {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = isOwnSpokenEcho(trimmed) ? "" : trimmed

        if !text.isEmpty {
            if let endAudioAt {
                if elapsedSinceListenStart - endAudioAt >= finalGrace {
                    return .promotePartial(text)
                }
                return .wait
            }
            if let silence, silence >= partialSilence {
                return .endAudio
            }
            if elapsedSinceListenStart >= maxListen {
                return .endAudio
            }
            return .wait
        }

        if elapsedSinceListenStart >= noFinalTimeout {
            return .missedPrompt
        }
        return .wait
    }

    /// Round-trip note for the retry prompt. No `stt_source` field.
    public static func noFinalLogNote(routeToken: String?) -> String {
        var note = "speechkit_no_final timeout_s=\(Int(noFinalTimeout)) restart_listening"
        if let routeToken, !routeToken.isEmpty, routeToken != "none" {
            note += " route=\(routeToken)"
        }
        return note
    }

    /// True when the transcript is only a line we just spoke (open or retry).
    public static func isOwnSpokenEcho(_ text: String) -> Bool {
        let spoken = normalizedUtterance(text)
        guard spoken.count >= 8 else { return false }
        let echoes = [GoldenSpokenLine.start, GoldenSpokenLine.noFinal].map(normalizedUtterance)
        return echoes.contains { echo in
            spoken == echo || echo.hasPrefix(spoken)
        }
    }

    public static func normalizedUtterance(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words.joined(separator: " ")
    }
}
