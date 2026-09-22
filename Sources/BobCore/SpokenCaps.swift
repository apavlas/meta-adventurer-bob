import Foundation

/// Spoken-line budget for glasses playback.
public enum SpokenRole: String, Codable, Sendable {
    /// Session open. Cap: ≤12 words.
    case open
    /// Normal Bob reply. Cap: ≤2 sentences / ~35 words.
    case reply
    /// Session end. Cap: one sentence.
    case end
    /// Session / bridge failure. Cap: one sentence.
    case fail
    /// Open-ear prompt when live STT produced no final. Cap: one sentence, ≤12 words.
    case retry
}

public enum SpokenCaps: Sendable {
    public static let openMaxWords = 12
    public static let replyMaxWords = 35
    public static let replyMaxSentences = 2

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }

    public static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let pieces = trimmed.split { ".!?".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(pieces.count, 1)
    }

    public static func isWithinCaps(role: SpokenRole, spokenLine: String) -> Bool {
        switch role {
        case .open:
            return wordCount(spokenLine) <= openMaxWords
        case .reply:
            return wordCount(spokenLine) <= replyMaxWords
                && sentenceCount(spokenLine) <= replyMaxSentences
        case .end, .fail:
            return sentenceCount(spokenLine) <= 1
        case .retry:
            return sentenceCount(spokenLine) <= 1
                && wordCount(spokenLine) <= openMaxWords
        }
    }

    /// If a desk-length answer exceeds reply caps, speak the over-budget line and keep the rest in `desk_full`.
    public static func enforceReply(spokenLine: String, deskFull: String?) -> BobBridgeResponse {
        if isWithinCaps(role: .reply, spokenLine: spokenLine) {
            return BobBridgeResponse(spokenLine: spokenLine, deskFull: deskFull)
        }
        return BobBridgeResponse(
            spokenLine: GoldenSpokenLine.overBudget,
            deskFull: deskFull ?? spokenLine
        )
    }
}
