import BobCore
import Foundation

#if canImport(MWDATCore)
import MWDATCore
#endif
#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

enum MockDeviceBootstrap {
    /// Official MockDeviceKit path: enable fake registration/device providers, then pair `.metaGlasses`.
    static func enable() {
        #if canImport(MWDATMockDevice)
        let kit = MockDeviceKit.shared
        if kit.isEnabled { return }
        kit.enable(
            config: MockDeviceKitConfig(
                initiallyRegistered: true,
                initialPermissionsGranted: true
            )
        )
        print("[DAT] MockDeviceKit.enabled initiallyRegistered=true meta_ai=none")
        #else
        print("[DAT] MWDATMockDevice unavailable — pair is stubbed")
        #endif
    }
}

struct PairedMockDevice: Sendable {
    var deviceType: String
    var glassesModel: String
    var note: String
}

enum WearableSessionError: Error, LocalizedError {
    case mockKitUnavailable
    case pairFailed(String)
    case sessionFailed(String)
    case notPaired

    var errorDescription: String? {
        switch self {
        case .mockKitUnavailable:
            return "MockDeviceKit is not linked in this build."
        case .pairFailed(let message):
            return message
        case .sessionFailed(let message):
            return message
        case .notPaired:
            return "Pair .metaGlasses before starting a session."
        }
    }
}

/// DAT mock pair / register / session. Camera stays off for voice v0.
@MainActor
final class DATMockWearableSession {
    private(set) var paired: PairedMockDevice?
    private(set) var registration = "unknown"
    private(set) var sessionState = "idle"
    private(set) var sessionId: String?

    #if canImport(MWDATMockDevice)
    private var mockGlasses: (any MockGlasses)?
    #endif
    #if canImport(MWDATCore)
    private var deviceSession: DeviceSession?
    private var stateTask: Task<Void, Never>?
    #endif

    func pairMetaGlasses() async throws -> PairedMockDevice {
        MockDeviceBootstrap.enable()

        #if canImport(MWDATMockDevice)
        let kit = MockDeviceKit.shared
        let glasses = try kit.pairGlasses(model: .metaGlasses)
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        mockGlasses = glasses

        let info = PairedMockDevice(
            deviceType: HardwareContext.deviceTypeLogValue,
            glassesModel: HardwareContext.glassesModelSymbol,
            note: "GlassesModel.metaGlasses variant=\(HardwareContext.variant)"
        )
        paired = info
        await refreshRegistration(expectMock: true)
        print("[DAT] paired model=.\(info.glassesModel) deviceType=\(info.deviceType) \(info.note)")
        return info
        #else
        let info = PairedMockDevice(
            deviceType: HardwareContext.deviceTypeLogValue,
            glassesModel: HardwareContext.glassesModelSymbol,
            note: "DAT XCFramework not present in this compile"
        )
        paired = info
        registration = "registered (compile-stub, no Meta AI)"
        return info
        #endif
    }

    func startDeviceSession() async throws -> String {
        guard paired != nil else { throw WearableSessionError.notPaired }

        #if canImport(MWDATCore)
        stopDeviceSession()
        let wearables = Wearables.shared
        let selector: DeviceSelector
        #if canImport(MWDATMockDevice)
        if let glasses = mockGlasses {
            selector = SpecificDeviceSelector(device: glasses.deviceIdentifier)
        } else {
            selector = AutoDeviceSelector(wearables: wearables)
        }
        #else
        selector = AutoDeviceSelector(wearables: wearables)
        #endif

        let session = try wearables.createSession(deviceSelector: selector)
        deviceSession = session
        let id = UUID().uuidString
        sessionId = id

        let started = Task {
            for await state in session.stateStream() {
                await MainActor.run {
                    self.sessionState = String(describing: state)
                    print("[DAT] DeviceSession.state=\(state)")
                }
                if state == .started { return }
                if state == .stopped {
                    throw WearableSessionError.sessionFailed("DeviceSession stopped before start")
                }
            }
        }

        try session.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await started.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw WearableSessionError.sessionFailed("DeviceSession start timed out")
            }
            try await group.next()
            group.cancelAll()
        }
        // Voice v0: do not call session.addCamera / Stream. Camera stays off.
        print("[DAT] DeviceSession.started session_id=\(id) camera=off")
        return id
        #else
        let id = UUID().uuidString
        sessionId = id
        sessionState = "started (compile-stub)"
        return id
        #endif
    }

    func stopDeviceSession() {
        #if canImport(MWDATCore)
        stateTask?.cancel()
        stateTask = nil
        deviceSession?.stop()
        deviceSession = nil
        #endif
        sessionState = "stopped"
        sessionId = nil
    }

    private func refreshRegistration(expectMock: Bool) async {
        #if canImport(MWDATCore)
        let timeout = Task {
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let observe = Task {
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self.registration = "\(state)\(expectMock ? " (mock, no Meta AI)" : "")"
                    print("[DAT] registration=\(self.registration)")
                }
                if String(describing: state).lowercased().contains("registered") {
                    return
                }
                if String(describing: state).lowercased().contains("available") {
                    try? await Wearables.shared.startRegistration()
                }
            }
        }
        _ = await timeout.result
        observe.cancel()
        if !registration.lowercased().contains("registered") && expectMock {
            registration = "registered (mock initiallyRegistered, no Meta AI)"
        }
        #else
        registration = "registered (compile-stub, no Meta AI)"
        #endif
    }
}
