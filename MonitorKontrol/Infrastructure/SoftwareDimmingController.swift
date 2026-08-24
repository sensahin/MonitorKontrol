import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SoftwareDimmingController {
    private var shadeWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var appliedBrightness: [CGDirectDisplayID: Double] = [:]

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) throws {
        guard let screen = NSScreen.screens.first(where: { $0.monitorKontrolDisplayID == displayID }) else {
            removeShade(for: displayID)
            throw DisplayControlError.displayNotFound
        }

        let value = brightness.clampedToUnitInterval
        guard value < 0.995 else {
            removeShade(for: displayID)
            return
        }

        let window = shadeWindows[displayID] ?? makeShadeWindow(for: screen)
        window.setFrame(screen.frame, display: true)
        // Cap opacity so a user can always recover through visible controls.
        window.alphaValue = CGFloat(min((1 - value) * 0.9, 0.88))
        window.orderFrontRegardless()
        shadeWindows[displayID] = window
        appliedBrightness[displayID] = value
    }

    func restoreAll() {
        shadeWindows.values.forEach { $0.orderOut(nil) }
        shadeWindows.removeAll()
        appliedBrightness.removeAll()
    }

    func removeDisconnectedDisplays(validDisplayIDs: Set<CGDirectDisplayID>) {
        let disconnected = shadeWindows.keys.filter { !validDisplayIDs.contains($0) }
        disconnected.forEach(removeShade)
    }

    func updateShadeFrames() {
        for (displayID, window) in Array(shadeWindows) {
            guard let screen = NSScreen.screens.first(where: { $0.monitorKontrolDisplayID == displayID }) else {
                removeShade(for: displayID)
                continue
            }
            window.setFrame(screen.frame, display: true)
        }
    }

    func removeShade(for displayID: CGDirectDisplayID) {
        shadeWindows.removeValue(forKey: displayID)?.orderOut(nil)
        appliedBrightness.removeValue(forKey: displayID)
    }

    func brightnessApplied(to displayID: CGDirectDisplayID) -> Double? {
        appliedBrightness[displayID]
    }

    private func makeShadeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        window.isReleasedWhenClosed = false
        return window
    }

}
