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
    /// Call only when `BOB_USE_MOCK_DEVICE` resolves YES.
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
        print("[DAT] MockDeviceKit.enabled initiallyRegistered=true meta_ai=none device_path=mock")
        #else
        print("[DAT] MWDATMockDevice unavailable — pair is stubbed")
        #endif
    }
}

/// DAT mock pair / register / session. Camera stays off for voice v0.
/// Used only when the mock path gate is YES.
@MainActor
final class DATMockWearableSession: WearableSessionControlling {
    private(set) var paired: PairedGlasses?
    private(set) var registration = "unknown"
    private(set) var sessionState = "idle"
    var onChange: (@MainActor () -> Void)?

    var metaAIUsed: Bool { false }
    var isReadyToStartSession: Bool { paired != nil }

    #if canImport(MWDATMockDevice)
    private var mockGlasses: (any MockGlasses)?
    #endif
    #if canImport(MWDATCore)
    private var deviceSession: DeviceSession?
    private var stateTask: Task<Void, Never>?
    #endif

    func prepare() async throws -> PairedGlasses {
        MockDeviceBootstrap.enable()

        #if canImport(MWDATMockDevice)
        let kit = MockDeviceKit.shared
        let glasses = try kit.pairGlasses(model: .metaGlasses)
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        mockGlasses = glasses

        let info = PairedGlasses(
            deviceType: HardwareContext.deviceTypeLogValue,
            glassesModel: HardwareContext.glassesModelSymbol,
            note: "GlassesModel.metaGlasses variant=\(HardwareContext.variant)",
            metaAIUsed: false
        )
        paired = info
        await refreshRegistration(expectMock: true)
        print("[DAT] paired model=.\(info.glassesModel) deviceType=\(info.deviceType) device_path=mock \(info.note)")
        return info
        #else
        let info = PairedGlasses(
            deviceType: HardwareContext.deviceTypeLogValue,
            glassesModel: HardwareContext.glassesModelSymbol,
            note: "DAT XCFramework not present in this compile",
            metaAIUsed: false
        )
        paired = info
        registration = "registered (compile-stub, no Meta AI)"
        publish()
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

        let started = Task { @MainActor in
            for await state in session.stateStream() {
                self.sessionState = String(describing: state)
                self.publish()
                print("[DAT] DeviceSession.state=\(state) device_path=mock")
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
        print("[DAT] DeviceSession.started session_id=\(id) camera=off device_path=mock")
        return id
        #else
        let id = UUID().uuidString
        sessionState = "started (compile-stub)"
        publish()
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
        publish()
    }

    private func refreshRegistration(expectMock: Bool) async {
        #if canImport(MWDATCore)
        let timeout = Task {
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let observe = Task { @MainActor in
            for await state in Wearables.shared.registrationStateStream() {
                self.registration = "\(state)\(expectMock ? " (mock, no Meta AI)" : "")"
                self.publish()
                print("[DAT] registration=\(self.registration)")
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
            publish()
        }
        #else
        registration = "registered (compile-stub, no Meta AI)"
        publish()
        #endif
    }

    private func publish() {
        onChange?()
    }
}
