import XCTest
@testable import BobCore

final class DevicePathConfigurationTests: XCTestCase {
    func testMissingFlagDefaultsToRealMockOff() {
        let config = DevicePathConfiguration.resolve(environment: [:], infoDictionary: [:])
        XCTAssertFalse(config.useMockDevice)
        XCTAssertEqual(config.path, .real)
        XCTAssertNil(config.rawValue)
        XCTAssertTrue(config.logLine.contains("resolved=real"))
        XCTAssertTrue(config.logLine.contains("mock_kit=off"))
    }

    func testUnexpandedPlaceholderIsIgnored() {
        let config = DevicePathConfiguration.resolve(
            environment: [:],
            infoDictionary: [DevicePathConfiguration.key: "$(BOB_USE_MOCK_DEVICE)"]
        )
        XCTAssertFalse(config.useMockDevice)
        XCTAssertEqual(config.path, .real)
    }

    func testExplicitNoAndUnknownStayReal() {
        for raw in ["NO", "no", "false", "0", "n", "maybe"] {
            let config = DevicePathConfiguration.resolve(
                environment: [DevicePathConfiguration.key: raw],
                infoDictionary: [DevicePathConfiguration.key: "YES"]
            )
            XCTAssertFalse(config.useMockDevice, raw)
            XCTAssertEqual(config.path, .real, raw)
        }
    }

    func testExplicitYesTokensEnableMock() {
        for raw in ["YES", "yes", "Yes", "true", "TRUE", "1", "y", "  YES  "] {
            let config = DevicePathConfiguration.resolve(
                environment: [:],
                infoDictionary: [DevicePathConfiguration.key: raw]
            )
            XCTAssertTrue(config.useMockDevice, raw)
            XCTAssertEqual(config.path, .mock, raw)
            XCTAssertTrue(config.logLine.contains("mock_kit=enable"))
        }
    }

    func testEnvironmentOverridesInfoPlist() {
        let mockOverride = DevicePathConfiguration.resolve(
            environment: [DevicePathConfiguration.key: "YES"],
            infoDictionary: [DevicePathConfiguration.key: "NO"]
        )
        XCTAssertTrue(mockOverride.useMockDevice)

        let realOverride = DevicePathConfiguration.resolve(
            environment: [DevicePathConfiguration.key: "NO"],
            infoDictionary: [DevicePathConfiguration.key: "YES"]
        )
        XCTAssertFalse(realOverride.useMockDevice)
        XCTAssertEqual(realOverride.rawValue, "NO")
    }

    func testRoundTripLineShowsPathAndMetaAI() {
        let real = RoundTripEntry(
            path: .reply,
            sttSource: .phoneMic,
            sttCapture: .live,
            sessionId: "s-real",
            spokenLine: GoldenSpokenLine.reply,
            spokenRole: .reply,
            metaAIUsed: true,
            devicePath: .real,
            note: "hfp_not_wired"
        )
        XCTAssertTrue(real.consoleLine.contains("device_path=real"))
        XCTAssertTrue(real.consoleLine.contains("meta_ai=used"))
        XCTAssertTrue(real.consoleLine.contains("stt_source=phone_mic"))
        XCTAssertTrue(real.consoleLine.contains("deviceType=META_GLASSES"))
        XCTAssertFalse(real.consoleLine.contains("stt_source=hfp"))

        let mock = RoundTripEntry(
            path: .start,
            spokenLine: GoldenSpokenLine.start,
            spokenRole: .open,
            metaAIUsed: false,
            devicePath: .mock
        )
        XCTAssertTrue(mock.consoleLine.contains("device_path=mock"))
        XCTAssertTrue(mock.consoleLine.contains("meta_ai=none"))
    }
}
