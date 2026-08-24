import AppKit
import SwiftUI

@main
struct MonitorKontrolApp: App {
    @StateObject private var displayManager = DisplayManager()

    var body: some Scene {
        MenuBarExtra(
            "MonitorKontrol",
            systemImage: "display.2",
            isInserted: Binding(
                get: { displayManager.isMenuBarInserted },
                set: { inserted in
                    guard displayManager.isMenuBarInserted != inserted else { return }
                    displayManager.isMenuBarInserted = inserted
                }
            )
        ) {
            MenuBarView(manager: displayManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(manager: displayManager)
        }
        .defaultSize(width: 620, height: 520)
    }
}
