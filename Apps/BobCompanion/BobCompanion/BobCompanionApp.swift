import BobCore
import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct BobCompanionApp: App {
    @StateObject private var session = CompanionSessionController()

    init() {
        let path = DevicePathConfiguration.resolve()
        print(path.logLine)
        DATBootstrap.prepare(useMockDevice: path.useMockDevice)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onOpenURL { url in
                    #if canImport(MWDATCore)
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                    #endif
                }
        }
    }
}

enum DATBootstrap {
    /// Configure DAT. `MockDeviceKit.enable` runs only when `BOB_USE_MOCK_DEVICE` resolves YES.
    /// Device runs default to real: `Wearables.configure()` and no mock providers.
    static func prepare(useMockDevice: Bool) {
        #if canImport(MWDATCore)
        configureWearables()
        #endif

        guard useMockDevice else {
            print("[DAT] BOB_USE_MOCK_DEVICE=NO — MockDeviceKit.enable not called")
            return
        }

        #if canImport(MWDATMockDevice)
        MockDeviceBootstrap.enable()
        #else
        print("[DAT] BOB_USE_MOCK_DEVICE=YES but MWDATMockDevice is not linked")
        #endif
    }

    #if canImport(MWDATCore)
    private static func configureWearables() {
        do {
            try Wearables.configure()
            print("[DAT] Wearables.configure ok")
        } catch let error as WearablesError
            where error.rawValue == WearablesError.alreadyConfigured.rawValue
        {
            print("[DAT] Wearables.configure alreadyConfigured")
        } catch {
            print("[DAT] Wearables.configure failed \(error)")
        }
    }
    #endif
}
