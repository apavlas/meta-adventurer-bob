import BobCore
import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct BobCompanionApp: App {
    @StateObject private var session = CompanionSessionController()

    init() {
        DATBootstrap.prepareMockPath()
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
    /// Enable MockDeviceKit before the first SwiftUI frame so DAT registration
    /// uses fake providers. `initiallyRegistered: true` means no Meta AI hop.
    static func prepareMockPath() {
        #if canImport(MWDATCore)
        do {
            try Wearables.configure()
        } catch {
            // MockDeviceKit.enable auto-configures Wearables if needed;
            // a second configure() throws alreadyConfigured.
        }
        #endif

        #if canImport(MWDATMockDevice)
        importMockAndEnable()
        #endif
    }

    #if canImport(MWDATMockDevice)
    private static func importMockAndEnable() {
        MockDeviceBootstrap.enable()
    }
    #endif
}
