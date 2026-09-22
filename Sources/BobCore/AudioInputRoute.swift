import Foundation

/// Whether the active capture input is a Bluetooth hands-free route.
/// `wired` is the flip of `not_wired`: HFP/SCO is the input right now.
public enum HFPRouteState: String, Codable, Sendable, Equatable {
    case wired
    case notWired = "not_wired"
}

/// One input port, described without AVFoundation so the rule can be tested on any host.
public struct AudioInputPort: Equatable, Sendable {
    public var portType: String
    public var portName: String

    public init(portType: String, portName: String) {
        self.portType = portType
        self.portName = portName
    }
}

/// Honest STT tag for the current input route.
/// `hfp` is chosen only when the route itself is HFP/SCO or a clear glasses hands-free port.
public struct AudioInputDecision: Equatable, Sendable {
    public var sttSource: STTSource
    public var hfpState: HFPRouteState
    public var portType: String
    public var portName: String
    public var audioRoute: String

    public var loggedRoute: String? {
        audioRoute == "none" || audioRoute.isEmpty ? nil : audioRoute
    }

    /// UI / status fragment. Omits `audio_route` until a port has been read.
    public var statusFragment: String {
        var parts = [
            "stt_source=\(sttSource.rawValue)",
            "hfp=\(hfpState.rawValue)",
        ]
        if let loggedRoute {
            parts.append("audio_route=\(loggedRoute)")
        }
        return parts.joined(separator: " · ")
    }

    public var logLine: String { "[Audio] \(statusFragment)" }
}

/// Classifies `AVAudioSession` input ports.
///
/// Apple's HFP/SCO input port type is `BluetoothHFP`. A2DP is output-only and is not a microphone.
/// Built-in and wired inputs stay `phone_mic` even if the port name mentions the glasses.
public enum AudioInputClassifier {
    /// `AVAudioSession.Port.bluetoothHFP` raw value.
    public static let bluetoothHFPPortType = "BluetoothHFP"

    public static func decide(inputs: [AudioInputPort], allowsHFP: Bool) -> AudioInputDecision {
        if allowsHFP, let index = preferredHFPIndex(in: inputs) {
            return make(inputs[index], source: .hfp, state: .wired)
        }
        return make(inputs.first, source: .phoneMic, state: .notWired)
    }

    /// Index to pass to `setPreferredInput`. Glasses-named HFP wins when several hands-free inputs exist.
    public static func preferredHFPIndex(in inputs: [AudioInputPort]) -> Int? {
        let matches = inputs.indices.filter {
            isHFPInput(portType: inputs[$0].portType, portName: inputs[$0].portName)
        }
        if let glasses = matches.first(where: { namesGlasses(inputs[$0].portName) || namesGlasses(inputs[$0].portType) }) {
            return glasses
        }
        return matches.first
    }

    public static func isHFPInput(portType: String, portName: String) -> Bool {
        if isNonHFPPortType(portType) { return false }
        if isBluetoothHFPPortType(portType) { return true }
        return isClearGlassesHandsFreePort(portType: portType, portName: portName)
    }

    /// Space-free debug token: `BluetoothHFP:Meta_Glasses`.
    public static func routeToken(portType: String, portName: String) -> String {
        let type = sanitize(portType)
        let name = sanitize(portName)
        let token: String
        if type.isEmpty && name.isEmpty {
            token = "none"
        } else if name.isEmpty {
            token = type
        } else if type.isEmpty {
            token = name
        } else {
            token = "\(type):\(name)"
        }
        if token.count > 120 {
            return String(token.prefix(120))
        }
        return token
    }

    private static func make(_ port: AudioInputPort?, source: STTSource, state: HFPRouteState) -> AudioInputDecision {
        let portType = port?.portType ?? ""
        let portName = port?.portName ?? ""
        return AudioInputDecision(
            sttSource: source,
            hfpState: state,
            portType: portType,
            portName: portName,
            audioRoute: routeToken(portType: portType, portName: portName)
        )
    }

    /// Built-in, wired, continuity, and A2DP inputs are not the glasses SCO mic.
    private static func isNonHFPPortType(_ portType: String) -> Bool {
        let compact = compact(portType)
        if compact.contains("a2dp") { return true }
        if compact.contains("builtin") { return true }
        if compact.contains("wired") { return true }
        if compact.contains("continuity") { return true }
        return false
    }

    private static func isBluetoothHFPPortType(_ portType: String) -> Bool {
        let folded = compact(portType)
        return folded.contains("hfp") || folded.contains("sco")
    }

    /// A port that is not typed `BluetoothHFP` but is unmistakably the glasses hands-free input.
    private static func isClearGlassesHandsFreePort(portType: String, portName: String) -> Bool {
        let handsFree = containsHandsFreeMarker(portType) || containsHandsFreeMarker(portName)
        guard handsFree else { return false }
        let type = portType.lowercased()
        let name = portName.lowercased()
        if type.contains("bluetooth") || name.contains("bluetooth") { return true }
        return namesGlasses(portName) || namesGlasses(portType)
    }

    private static func containsHandsFreeMarker(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.contains("hands-free") || lower.contains("handsfree") || lower.contains("hand free") {
            return true
        }
        let tokens = tokenParts(raw)
        if tokens.contains(where: { $0.contains("hfp") }) { return true }
        return tokens.contains("sco")
    }

    private static func namesGlasses(_ raw: String) -> Bool {
        let name = raw.lowercased()
        if name.contains("adventurer") { return true }
        if name.contains("ray-ban") || name.contains("rayban") || name.contains("ray ban") { return true }
        if name.contains("glasses") { return true }
        if name.contains("meta ai") { return true }
        return tokenParts(raw).contains("meta")
    }

    private static func compact(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func tokenParts(_ raw: String) -> [String] {
        raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func sanitize(_ raw: String) -> String {
        var parts: [String] = []
        var current = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == ":" || scalar.value < 32 {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            current.append(Character(scalar))
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts.joined(separator: "_")
    }
}
