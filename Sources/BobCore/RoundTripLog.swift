import Foundation

public enum GoldenPath: String, Codable, Sendable {
    case start
    case reply
    case overBudget = "over_budget"
    case fail
    case end
}

public enum STTCapture: String, Codable, Sendable {
    /// Live `SFSpeechRecognizer` from the phone microphone.
    case live
    /// Injected demo utterance so the first proof can log without speaking.
    case demoInjected = "demo_injected"
}

public struct RoundTripEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var path: GoldenPath
    public var deviceType: String
    public var sttSource: STTSource?
    public var sttCapture: STTCapture?
    public var sessionId: String?
    public var spokenLine: String
    public var spokenRole: SpokenRole
    public var deskFull: String?
    public var metaAIUsed: Bool
    public var devicePath: DevicePathKind
    public var hfpState: HFPRouteState?
    public var audioRoute: String?
    public var note: String

    public init(
        id: String = uniqueEntryID(),
        path: GoldenPath,
        deviceType: String = HardwareContext.deviceTypeLogValue,
        sttSource: STTSource? = nil,
        sttCapture: STTCapture? = nil,
        sessionId: String? = nil,
        spokenLine: String,
        spokenRole: SpokenRole,
        deskFull: String? = nil,
        metaAIUsed: Bool = false,
        devicePath: DevicePathKind = .real,
        hfpState: HFPRouteState? = nil,
        audioRoute: String? = nil,
        note: String = ""
    ) {
        self.id = id
        self.path = path
        self.deviceType = deviceType
        self.sttSource = sttSource
        self.sttCapture = sttCapture
        self.sessionId = sessionId
        self.spokenLine = spokenLine
        self.spokenRole = spokenRole
        self.deskFull = deskFull
        self.metaAIUsed = metaAIUsed
        self.devicePath = devicePath
        self.hfpState = hfpState
        self.audioRoute = audioRoute
        self.note = note
    }

    public var spokenWordCount: Int { SpokenCaps.wordCount(spokenLine) }
    public var spokenSentenceCount: Int { SpokenCaps.sentenceCount(spokenLine) }
    public var withinCaps: Bool { SpokenCaps.isWithinCaps(role: spokenRole, spokenLine: spokenLine) }

    public var consoleLine: String {
        var fields: [String] = [
            "path=\(path.rawValue)",
            "deviceType=\(deviceType)",
            "spoken_line=\(spokenLine)",
            "spoken_line_words=\(spokenWordCount)",
            "spoken_line_within_caps=\(withinCaps)",
            "device_path=\(devicePath.rawValue)",
            "meta_ai=\(metaAIUsed ? "used" : "none")",
        ]
        if let sttSource {
            fields.append("stt_source=\(sttSource.rawValue)")
        }
        if let hfpState {
            fields.append("hfp=\(hfpState.rawValue)")
        }
        if let audioRoute, !audioRoute.isEmpty, audioRoute != "none" {
            fields.append("audio_route=\(audioRoute)")
        }
        if let sttCapture {
            fields.append("stt_capture=\(sttCapture.rawValue)")
        }
        if let sessionId {
            fields.append("session_id=\(sessionId)")
        }
        if let deskFull {
            fields.append("desk_full=\(deskFull)")
        }
        if !note.isEmpty {
            fields.append("note=\(note)")
        }
        return "[RoundTrip] " + fields.joined(separator: " ")
    }
}

public struct RoundTripLog: Equatable, Sendable {
    public var entries: [RoundTripEntry]

    public init(entries: [RoundTripEntry] = []) {
        self.entries = entries
    }

    public mutating func append(_ entry: RoundTripEntry) {
        print(entry.consoleLine)
        entries.insert(entry, at: 0)
    }

    public var hasCompleteReplyRoundTrip: Bool {
        let started = entries.contains { $0.path == .start }
        let replied = entries.contains { $0.path == .reply }
        return started && replied
    }
}

public func uniqueEntryID() -> String {
    "rt-\(UInt64.random(in: 1 ... UInt64.max))"
}
