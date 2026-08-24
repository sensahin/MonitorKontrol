import CoreGraphics
import Foundation
import Testing
@testable import MonitorKontrol

struct DisplayModelTests {
    @Test("Real serial numbers produce stable hardware identities")
    func stableIdentityUsesRealSerial() {
        let identity = DisplayIdentity.persistentID(
            vendorID: 0x1E6D,
            productID: 0x5B55,
            serialNumber: 0x12345678,
            displayUUID: "ignored",
            fallbackDisplayID: 3
        )

        #expect(identity == "1E6D-5B55-12345678")
    }

    @Test("LG placeholder serial falls back to the display UUID")
    func placeholderSerialUsesUUID() {
        let identity = DisplayIdentity.persistentID(
            vendorID: 0x1E6D,
            productID: 0x5B55,
            serialNumber: 0x01010101,
            displayUUID: "a1b2-c3d4",
            fallbackDisplayID: 3
        )

        #expect(identity == "1E6D-5B55-A1B2-C3D4")
    }

    @Test("Port identity separates identical displays with placeholder serials")
    func placeholderSerialUsesStableLocation() {
        let first = DisplayIdentity.persistentID(
            vendorID: 0x1E6D,
            productID: 0x5B55,
            serialNumber: 0x01010101,
            displayUUID: "same-generated-uuid",
            displayLocation: "IOService:/AppleARMPE/port-1/display",
            fallbackDisplayID: 3
        )
        let second = DisplayIdentity.persistentID(
            vendorID: 0x1E6D,
            productID: 0x5B55,
            serialNumber: 0x01010101,
            displayUUID: "same-generated-uuid",
            displayLocation: "IOService:/AppleARMPE/port-2/display",
            fallbackDisplayID: 4
        )
        let firstAgain = DisplayIdentity.persistentID(
            vendorID: 0x1E6D,
            productID: 0x5B55,
            serialNumber: 0x01010101,
            displayUUID: "same-generated-uuid",
            displayLocation: "IOService:/AppleARMPE/port-1/display",
            fallbackDisplayID: 9
        )

        #expect(first != second)
        #expect(first == firstAgain)
    }

    @Test("Scene fallback brightness cannot exceed the valid range", arguments: [
        (-0.5, 0.0),
        (0.42, 0.42),
        (1.5, 1.0),
    ])
    func sceneClampsFallback(input: Double, expected: Double) {
        let scene = DisplayScene(
            name: "Test",
            brightnessByDisplayID: [:],
            fallbackBrightness: input
        )

        #expect(scene.fallbackBrightness == expected)
    }

    @Test("Display settings and scenes round-trip through isolated defaults")
    func preferencesRoundTrip() throws {
        let suite = "MonitorKontrolTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)

        let settings = StoredDisplaySettings(brightness: 0.63, backendPreference: .software)
        store.save(settings, for: "LG")
        #expect(store.settings(for: "LG") == settings)

        let scene = DisplayScene(
            name: "Writing",
            brightnessByDisplayID: ["LG": 0.63],
            fallbackBrightness: 0.5
        )
        store.saveScenes([scene])
        #expect(store.loadScenes() == [scene])
    }
}
