import Foundation

/// How the real-path capture graph should be built for Adventurer HFP/SCO.
///
/// `hfp=wired` only means the session route is the glasses. SpeechKit still
/// gets nothing when the tap format does not match the SCO rate, or when
/// `.voiceChat` is set but the engine stays on Remote I/O instead of
/// VoiceProcessingIO. These rules are pure so the device log lines can be
/// tested without AVFoundation.
public enum HFPCaptureGraph: Sendable {
    /// HFP wideband (mSBC) rate. Leaving the session at 48 kHz after TTS
    /// makes the input converter deliver empty taps.
    public static let preferredSampleRate: Double = 16_000

    /// One SCO frame. SpeechKit accepts this buffer duration.
    public static let preferredIOBufferDuration: TimeInterval = 0.02

    /// How long to print tap energy after the tap is installed.
    public static let tapLogWindow: TimeInterval = 3

    /// Spacing of `[Audio] tap_energy` lines inside `tapLogWindow`.
    public static let tapLogInterval: TimeInterval = 0.5

    /// After the engine starts, HFP may renegotiate once the uplink leaves playback.
    public static let scoFormatSettle: TimeInterval = 0.35

    /// Peak at or above this is treated as real samples, not a zeroed tap.
    public static let silencePeak: Float = 0.005

    public static func shouldEnableVoiceProcessing(allowsHFP: Bool) -> Bool {
        allowsHFP
    }

    /// True when the running tap bus is not the SCO hardware format.
    /// Restart the engine after the session is activated again so the bus can renegotiate.
    /// Do not connect the input node while voice processing is enabled: that graph
    /// plays the mic back into the glasses and fights VoiceProcessingIO.
    public static func shouldForceHardwareFormat(
        outputRate: Double,
        outputChannels: Int,
        hardwareRate: Double,
        hardwareChannels: Int
    ) -> Bool {
        guard hardwareRate > 0, hardwareChannels > 0 else { return false }
        if outputRate <= 0 || outputChannels <= 0 { return true }
        if abs(outputRate - hardwareRate) >= 1 { return true }
        if outputChannels != hardwareChannels { return true }
        return false
    }

    public static func hasAudibleEnergy(peak: Float, bufferCount: Int) -> Bool {
        bufferCount > 0 && peak >= silencePeak
    }

    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> LevelReading {
        guard !samples.isEmpty else { return LevelReading(rms: 0, peak: 0) }
        var peak: Float = 0
        var sum: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sum += sample * sample
        }
        return LevelReading(rms: sqrt(sum / Float(samples.count)), peak: peak)
    }

    public static func louder(_ lhs: LevelReading, _ rhs: LevelReading) -> LevelReading {
        if rhs.peak > lhs.peak { return rhs }
        if lhs.peak > rhs.peak { return lhs }
        return rhs.rms > lhs.rms ? rhs : lhs
    }

    public static func formatLogLine(
        sessionRate: Double,
        hardwareRate: Double,
        hardwareChannels: Int,
        outputRate: Double,
        outputChannels: Int,
        voiceProcessing: Bool
    ) -> String {
        "[Audio] formats session_rate=\(roundedRate(sessionRate)) hardware_rate=\(roundedRate(hardwareRate)) hardware_channels=\(hardwareChannels) output_rate=\(roundedRate(outputRate)) output_channels=\(outputChannels) voice_processing=\(voiceProcessing ? "on" : "off")"
    }

    public static func partialLogLine(chars: Int, isFinal: Bool) -> String {
        "[Audio] partial chars=\(chars) is_final=\(isFinal ? "true" : "false")"
    }

    public static func firstBufferLogLine(summary: CaptureEnergySummary) -> String {
        "[Audio] tap_first \(summary.logFragment)"
    }

    public static func tapEnergyLogLine(seconds: TimeInterval, summary: CaptureEnergySummary) -> String {
        "[Audio] tap_energy t=\(decimal1(seconds))s \(summary.logFragment)"
    }

    public static func tapEnergySummaryLogLine(audible: Bool, summary: CaptureEnergySummary) -> String {
        "[Audio] tap_energy_summary audible=\(audible ? "true" : "false") \(summary.logFragment)"
    }

    public static func roundedRate(_ rate: Double) -> Int {
        Int(rate.rounded())
    }

    public static func decimal1(_ value: TimeInterval) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func decimal4(_ value: Float) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}

public struct LevelReading: Equatable, Sendable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }
}

/// Tap evidence for one listen window. `rms` is the latest buffer. `peak` is the max.
/// No `stt_source` field: a silent tap is not an HFP transcript.
public struct CaptureEnergySummary: Equatable, Sendable {
    public var bufferCount: Int
    public var peak: Float
    public var rms: Float
    public var sampleRate: Double
    public var channels: Int
    public var partialEvents: Int

    public init(
        bufferCount: Int = 0,
        peak: Float = 0,
        rms: Float = 0,
        sampleRate: Double = 0,
        channels: Int = 0,
        partialEvents: Int = 0
    ) {
        self.bufferCount = bufferCount
        self.peak = peak
        self.rms = rms
        self.sampleRate = sampleRate
        self.channels = channels
        self.partialEvents = partialEvents
    }

    public var logFragment: String {
        "tap_buffers=\(bufferCount) tap_rms=\(HFPCaptureGraph.decimal4(rms)) tap_peak=\(HFPCaptureGraph.decimal4(peak)) sample_rate=\(HFPCaptureGraph.roundedRate(sampleRate)) channels=\(channels) partial_events=\(partialEvents)"
    }
}
