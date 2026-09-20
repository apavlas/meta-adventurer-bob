import Foundation

/// Golden `spoken_line` values for the first logged mock round-trip.
public enum GoldenSpokenLine: Sendable {
    /// Session start / open. Cap: ≤12 words.
    public static let start = "Bob here. Listening."

    /// Stub Bob reply. Cap: ≤2 sentences / ~35 words.
    public static let reply = "Next up is the 2pm with Sue."

    /// Over-budget spoken fallback. Full text goes in `desk_full`.
    public static let overBudget = "Full note on desk."

    /// Session / bridge failure. Cap: one sentence.
    public static let fail = "Session cut — check the phone."

    /// Session end. Cap: one sentence.
    public static let end = "Paused — say Bob when you’re back."
}

/// Hardware context for this companion. Mock pairs DAT `.metaGlasses`, not Ray-Ban Meta or Display.
public enum HardwareContext: Sendable {
    public static let productName = "Meta Adventurer"
    public static let variant = "1H41"
    public static let deviceTypeLogValue = "META_GLASSES"
    public static let glassesModelSymbol = "metaGlasses"
}
