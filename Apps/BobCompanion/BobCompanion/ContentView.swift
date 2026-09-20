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
                await session.bootstrapMock()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chief of Staff")
                .font(.title2.weight(.semibold))
            Text("\(HardwareContext.productName) · variant \(HardwareContext.variant) · mock \(HardwareContext.deviceTypeLogValue)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Status", session.status)
            labeled("Registration", session.registration)
            labeled("Device session", session.sessionState)
            labeled("STT", session.liveSTTAvailable ? "phone_mic live" : "phone_mic (demo inject until mic is granted)")
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
            Text("Talk to Bob already logs start + stub reply. These inject extra phone_mic utterances.")
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
                Text("Pair, then tap Talk to Bob. Console and this list should show deviceType=META_GLASSES, stt_source=phone_mic, and spoken_line caps.")
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
