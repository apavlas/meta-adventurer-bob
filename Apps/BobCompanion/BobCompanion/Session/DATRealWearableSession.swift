import BobCore
import Foundation

#if canImport(MWDATCore)
import MWDATCore
#endif

/// Real DAT path: `Wearables.configure` (done at launch), Meta AI registration, then a
/// `DeviceSession` on `.metaGlasses` only. This type never imports or calls MockDeviceKit.
///
/// Audio capture is not a DAT API. The companion tags `stt_source` from the iOS input
/// route after this session starts: `hfp` only when that route is Bluetooth HFP/SCO.
@MainActor
final class DATRealWearableSession: WearableSessionControlling {
    private(set) var registration = "unknown"
    private(set) var sessionState = "idle"
    private(set) var metaAIUsed = false
    var onChange: (@MainActor () -> Void)?

    var isReadyToStartSession: Bool { metaAIUsed && selectedDeviceID != nil }

    private var selectedDeviceID: String?
    private var seenDeviceTypes = ""
    private var permissionNote = ""
    private var didRequestCameraPermission = false
    private var startedObservers = false

    #if canImport(MWDATCore)
    private var deviceSession: DeviceSession?
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    #endif

    func prepare() async throws -> PairedGlasses {
        #if canImport(MWDATCore)
        startObserving()
        refreshFromSnapshots()
        if !metaAIUsed {
            await waitForRegistration(seconds: 1)
        }

        if !metaAIUsed {
            do {
                registration = registration == "unknown" ? "registering" : registration
                publish()
                try await Wearables.shared.startRegistration()
                refreshFromSnapshots()
            } catch let error as RegistrationError
                where error.rawValue == RegistrationError.alreadyRegistered.rawValue
            {
                markRegistered()
            } catch {
                let message = "Meta AI registration failed: \(error.localizedDescription). Install Meta AI, turn on Developer Mode, and connect the Adventurer."
                registration = "unavailable"
                publish()
                throw WearableSessionError.registrationFailed(message)
            }
        }

        if metaAIUsed && selectedDeviceID == nil {
            _ = await waitForMetaGlasses(seconds: 1.5)
        }
        if metaAIUsed && selectedDeviceID == nil {
            await requestCameraPermissionIfNeeded()
            _ = await waitForMetaGlasses(seconds: 2)
        }

        let info = currentPairing()
        publish()
        print("[DAT] real prepare meta_ai=\(metaAIUsed ? "used" : "none") registration=\(registration) deviceType=\(info.deviceType) ready=\(isReadyToStartSession) \(info.note)")
        return info
        #else
        registration = "unavailable"
        publish()
        throw WearableSessionError.datUnavailable
        #endif
    }

    func startDeviceSession() async throws -> String {
        guard metaAIUsed else {
            throw WearableSessionError.registrationFailed(
                "Register with Meta AI before starting a session."
            )
        }

        #if canImport(MWDATCore)
        refreshFromSnapshots()
        guard let deviceID = selectedDeviceID else {
            throw WearableSessionError.noMetaGlasses
        }
        guard let device = Wearables.shared.deviceForIdentifier(deviceID),
              device.deviceType() == .metaGlasses
        else {
            selectedDeviceID = nil
            publish()
            throw WearableSessionError.noMetaGlasses
        }

        stopDeviceSession()
        let selector = SpecificDeviceSelector(device: deviceID)
        let wearables = Wearables.shared
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            throw WearableSessionError.sessionFailed(error.localizedDescription)
        }
        deviceSession = session
        let id = UUID().uuidString

        let started = Task { @MainActor in
            for await state in session.stateStream() {
                self.sessionState = state.description
                self.publish()
                print("[DAT] DeviceSession.state=\(state.description) device_path=real")
                if state == .started { return }
                if state == .stopped {
                    throw WearableSessionError.sessionFailed("DeviceSession stopped before start")
                }
            }
        }

        do {
            try session.start()
            if session.state != .started {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await started.value }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        throw WearableSessionError.sessionFailed("DeviceSession start timed out")
                    }
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch {
            started.cancel()
            let message = (error as? WearableSessionError)?.localizedDescription ?? error.localizedDescription
            throw WearableSessionError.sessionFailed(message)
        }
        started.cancel()
        guard session.state == .started else {
            throw WearableSessionError.sessionFailed("DeviceSession did not reach started")
        }
        // Voice v0: do not call addCamera. Camera permission may be requested only so DAT lists the device.
        sessionState = "started"
        publish()
        print("[DAT] DeviceSession.started session_id=\(id) camera=off device_path=real deviceType=\(HardwareContext.deviceTypeLogValue)")
        return id
        #else
        throw WearableSessionError.datUnavailable
        #endif
    }

    func stopDeviceSession() {
        #if canImport(MWDATCore)
        deviceSession?.stop()
        deviceSession = nil
        #endif
        sessionState = "stopped"
        publish()
    }

    #if canImport(MWDATCore)
    private func startObserving() {
        guard !startedObservers else { return }
        startedObservers = true
        registrationTask = Task { @MainActor in
            for await state in Wearables.shared.registrationStateStream() {
                self.apply(registration: state)
            }
        }
        devicesTask = Task { @MainActor in
            for await identifiers in Wearables.shared.devicesStream() {
                self.apply(deviceIDs: identifiers)
            }
        }
    }

    private func refreshFromSnapshots() {
        apply(registration: Wearables.shared.registrationState)
        apply(deviceIDs: Wearables.shared.devices)
    }

    private func apply(registration state: RegistrationState) {
        switch state {
        case .unavailable:
            registration = "unavailable"
            metaAIUsed = false
        case .available:
            registration = "available"
            metaAIUsed = false
        case .registering:
            registration = "registering"
            metaAIUsed = false
        case .registered:
            markRegistered()
            return
        }
        publish()
    }

    private func markRegistered() {
        registration = "registered"
        metaAIUsed = true
        publish()
    }

    private func apply(deviceIDs: [DeviceIdentifier]) {
        let wearables = Wearables.shared
        var seen: [String] = []
        var match: String?
        for identifier in deviceIDs {
            guard let device = wearables.deviceForIdentifier(identifier) else { continue }
            let type = device.deviceType()
            seen.append(type.rawValue)
            if type == .metaGlasses, match == nil {
                match = identifier
            }
        }
        seenDeviceTypes = seen.joined(separator: ",")
        selectedDeviceID = match
        print("[DAT] devicesStream count=\(deviceIDs.count) types=\(seenDeviceTypes.isEmpty ? "none" : seenDeviceTypes) selected_meta_glasses=\(match == nil ? "no" : "yes")")
        publish()
    }

    private func requestCameraPermissionIfNeeded() async {
        guard !didRequestCameraPermission else { return }
        didRequestCameraPermission = true
        permissionNote = "requesting camera permission so DAT can list devices; camera stream stays off"
        publish()
        do {
            let status = try await Wearables.shared.requestPermission(.camera)
            switch status {
            case .granted:
                permissionNote = "camera permission granted (stream stays off)"
            case .denied:
                permissionNote = "camera permission denied (stream stays off; devicesStream may stay empty)"
            }
        } catch {
            permissionNote = "camera permission error: \(error.localizedDescription) (stream stays off)"
        }
        refreshFromSnapshots()
        publish()
    }

    private func waitForRegistration(seconds: Double) async {
        let steps = Int(seconds / 0.2)
        for _ in 0 ..< steps {
            if metaAIUsed { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            refreshFromSnapshots()
        }
    }

    private func waitForMetaGlasses(seconds: Double) async -> Bool {
        let steps = Int(seconds / 0.2)
        if selectedDeviceID != nil { return true }
        for _ in 0 ..< steps {
            if selectedDeviceID != nil { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
            refreshFromSnapshots()
        }
        return selectedDeviceID != nil
    }
    #endif

    private func currentPairing() -> PairedGlasses {
        var note = "GlassesModel.metaGlasses variant=\(HardwareContext.variant)"
        if selectedDeviceID == nil {
            if seenDeviceTypes.isEmpty {
                note += " · no device in devicesStream yet"
            } else {
                note += " · devicesStream has \(seenDeviceTypes), not .metaGlasses"
            }
        } else {
            note += " · selected .metaGlasses"
        }
        if !permissionNote.isEmpty {
            note += " · \(permissionNote)"
        }
        return PairedGlasses(
            deviceType: HardwareContext.deviceTypeLogValue,
            glassesModel: HardwareContext.glassesModelSymbol,
            note: note,
            metaAIUsed: metaAIUsed
        )
    }

    private func publish() {
        onChange?()
    }
}
