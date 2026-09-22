import BobCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var session: CompanionSessionController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusBlock
                    ctaBlock
                    demoBlock
                    logBlock
                }
                .padding(20)
            }
            .navigationTitle("Bob")
            .task {
                await session.bootstrap()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chief of Staff")
                .font(.title2.weight(.semibold))
            Text(headerLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if session.usesMockDevice {
                Text("mock means MockDeviceKit is on. deviceType stays \(HardwareContext.deviceTypeLogValue).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerLine: String {
        let path = session.usesMockDevice ? "mock" : "real"
        return "\(HardwareContext.productName) · variant \(HardwareContext.variant) · path \(path) · \(HardwareContext.deviceTypeLogValue)"
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Status", session.status)
            labeled("Path", session.usesMockDevice ? "mock · MockDeviceKit" : "real · Meta AI")
            labeled("Registration", session.registration)
            labeled("Device session", session.sessionState)
            labeled("BobBridge", session.bridgeMode)
            labeled("STT", session.sttSummary)
            if !session.lastSpoken.isEmpty {
                labeled("Last spoken", session.lastSpoken)
            }
            if !session.lastUtterance.isEmpty {
                labeled("Last utterance", session.lastUtterance)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var ctaBlock: some View {
        VStack(spacing: 10) {
            Button {
                Task { await session.talkToBob() }
            } label: {
                Text(LexCopy.talkToBob)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isListening)

            Text(LexCopy.sessionSubtext)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                Task { await session.endSession() }
            } label: {
                Text(LexCopy.end)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(!session.isListening && session.phase != .thinking)
        }
    }

    private var demoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Golden-path demos")
                .font(.headline)
            Text(session.usesMockDevice
                ? "Talk to Bob logs start plus a demo phone_mic utterance. These buttons inject more."
                : "Talk to Bob starts a real DAT session. STT stays phone_mic until HFP is wired. These buttons inject phone_mic utterances.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                demoButton("Reply", .reply)
                demoButton("Desk", .overBudget)
                demoButton("Fail", .fail)
            }
        }
    }

    private var logBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Round-trip log")
                .font(.headline)
            if session.log.entries.isEmpty {
                Text(session.usesMockDevice
                    ? "Pair, then tap Talk to Bob. Console and this list should show device_path=mock, deviceType=META_GLASSES, meta_ai=none, stt_source=phone_mic."
                    : "With Meta AI Connected, tap Talk to Bob. Log shows device_path=real, deviceType=META_GLASSES, meta_ai=used, stt_source=phone_mic (HFP not wired).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.log.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.path.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(entry.spokenLine)
                            .font(.body)
                        Text(entry.consoleLine)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func demoButton(_ title: String, _ scenario: StubBobService.Scenario) -> some View {
        Button(title) {
            Task { await session.runDemo(scenario) }
        }
        .buttonStyle(.bordered)
        .disabled(!session.isListening)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}

#Preview {
    ContentView(session: CompanionSessionController())
}
