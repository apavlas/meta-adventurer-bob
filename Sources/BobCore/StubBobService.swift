import Foundation

/// Local Bob for the first mock proof. Replace with `BobBridgeClient` + a real transport later.
public struct StubBobService: BobServing {
    public enum Scenario: String, Sendable, CaseIterable {
        case reply
        case overBudget
        case fail
    }

    public var scenario: Scenario

    /// Desk-length answer used to exercise the over-budget spoken cap.
    public static let longDeskAnswer = """
        Sue’s 2pm is in the west conference room. Bring the Q3 deck, the hiring plan, and last week’s open questions. \
        Finance still wants a decision on the vendor shortlist before you walk in, and Alex asked you to confirm the headcount freeze exception.
        """

    public init(scenario: Scenario = .reply) {
        self.scenario = scenario
    }

    public func complete(_ request: BobBridgeRequest) async throws -> BobBridgeResponse {
        switch resolve(request) {
        case .fail:
            throw BobBridgeError.sessionCut
        case .overBudget:
            return SpokenCaps.enforceReply(
                spokenLine: Self.longDeskAnswer,
                deskFull: Self.longDeskAnswer
            )
        case .reply:
            return SpokenCaps.enforceReply(
                spokenLine: GoldenSpokenLine.reply,
                deskFull: nil
            )
        }
    }

    private func resolve(_ request: BobBridgeRequest) -> Scenario {
        let text = request.utterance.lowercased()
        if text.contains("fail") || text.contains("cut") {
            return .fail
        }
        if text.contains("full note") || text.contains("desk") || text.contains("over-budget") || text.contains("over budget") {
            return .overBudget
        }
        return scenario
    }
}
