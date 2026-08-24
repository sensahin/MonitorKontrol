import CoreGraphics
import Foundation
import Testing
@testable import MonitorKontrol

@Suite("Connected display hardware", .serialized)
struct HardwareIntegrationTests {
    @Test(
        "Brightness writes are readable and restore both displays",
        .enabled(
            if: ProcessInfo.processInfo.environment["MONITORKONTROL_HARDWARE_QA"] == "1",
            "Set MONITORKONTROL_HARDWARE_QA=1 to permit reversible display writes."
        )
    )
    @MainActor
    func brightnessWritesRestoreCapturedBaselines() async throws {
        let descriptors = DisplayDiscovery().discover()
        let builtIn = try #require(descriptors.first(where: { $0.isBuiltIn }))
        let external = try #require(descriptors.first {
            !$0.isBuiltIn && $0.vendorID == 0x1E6D && $0.productID == 0x5B55
        })

        let nativeController = NativeBrightnessController()
        let nativeBaseline = try nativeController.brightness(for: builtIn.displayID)

        let transport = DDCTransport()
        let endpoints = try await transport.discover(displayIDs: [external.displayID])
        let endpoint = try #require(endpoints.first(where: { $0.displayID == external.displayID }))
        let externalBaseline = try await transport.read(.brightness, from: endpoint)
        try #require(externalBaseline.maximum > 0)

        do {
            let externalStep = max(UInt16(1), externalBaseline.maximum / 20)
            let externalTarget = externalBaseline.current >= externalStep
                ? externalBaseline.current - externalStep
                : min(externalBaseline.maximum, externalBaseline.current + externalStep)

            try await transport.write(.brightness, value: externalTarget, to: endpoint, coalescing: false)
            try await Task.sleep(for: .milliseconds(350))
            let changedExternal = try await transport.read(.brightness, from: endpoint)

            try await restoreExternalBrightness(
                externalBaseline.current,
                transport: transport,
                endpoint: endpoint
            )
            let restoredExternal = try await transport.read(.brightness, from: endpoint)

            #expect(changedExternal.current == externalTarget)
            #expect(restoredExternal.current == externalBaseline.current)

            let nativeTarget = nativeBaseline >= 0.05
                ? nativeBaseline - 0.05
                : min(1, nativeBaseline + 0.05)
            try nativeController.setBrightness(nativeTarget, for: builtIn.displayID)
            try await Task.sleep(for: .milliseconds(250))
            let changedNative = try nativeController.brightness(for: builtIn.displayID)

            try await restoreNativeBrightness(
                nativeBaseline,
                controller: nativeController,
                displayID: builtIn.displayID
            )
            let restoredNative = try nativeController.brightness(for: builtIn.displayID)

            #expect(abs(changedNative - nativeTarget) < 0.015)
            #expect(abs(restoredNative - nativeBaseline) < 0.015)
        } catch {
            var restorationFailures: [String] = []
            do {
                try await restoreExternalBrightness(
                    externalBaseline.current,
                    transport: transport,
                    endpoint: endpoint
                )
            } catch let restorationError {
                restorationFailures.append("LG: \(restorationError.localizedDescription)")
            }
            do {
                try await restoreNativeBrightness(
                    nativeBaseline,
                    controller: nativeController,
                    displayID: builtIn.displayID
                )
            } catch let restorationError {
                restorationFailures.append("MacBook: \(restorationError.localizedDescription)")
            }
            if !restorationFailures.isEmpty {
                let restorationError = HardwareQAError.restorationFailed(
                    restorationFailures.joined(separator: "; ")
                )
                Issue.record("Original failure: \(error). Restoration also failed: \(restorationError)")
                throw restorationError
            }
            throw error
        }
    }

    private func restoreExternalBrightness(
        _ baseline: UInt16,
        transport: DDCTransport,
        endpoint: DDCDisplayEndpoint
    ) async throws {
        var lastError: Error = HardwareQAError.restorationFailed("No LG restore attempt completed.")

        for attempt in 0..<4 {
            do {
                try await transport.write(
                    .brightness,
                    value: baseline,
                    to: endpoint,
                    coalescing: false
                )
                try await Task.sleep(for: .milliseconds(500 + attempt * 250))
                let restored = try await transport.read(.brightness, from: endpoint)
                if restored.current == baseline { return }
                lastError = HardwareQAError.restorationMismatch(
                    expected: baseline,
                    actual: restored.current
                )
            } catch {
                lastError = error
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw lastError
    }

    private func restoreNativeBrightness(
        _ baseline: Double,
        controller: NativeBrightnessController,
        displayID: CGDirectDisplayID
    ) async throws {
        var lastError: Error = HardwareQAError.restorationFailed(
            "No MacBook restore attempt completed."
        )

        for attempt in 0..<4 {
            do {
                try controller.setBrightness(baseline, for: displayID)
                try await Task.sleep(for: .milliseconds(250 + attempt * 150))
                let restored = try controller.brightness(for: displayID)
                if abs(restored - baseline) < 0.015 { return }
                lastError = HardwareQAError.nativeRestorationMismatch(
                    expected: baseline,
                    actual: restored
                )
            } catch {
                lastError = error
            }
        }

        throw lastError
    }
}

private enum HardwareQAError: LocalizedError {
    case restorationMismatch(expected: UInt16, actual: UInt16)
    case nativeRestorationMismatch(expected: Double, actual: Double)
    case restorationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .restorationMismatch(expected, actual):
            "Expected restored brightness \(expected), but read \(actual)."
        case let .nativeRestorationMismatch(expected, actual):
            "Expected restored MacBook brightness \(expected), but read \(actual)."
        case let .restorationFailed(message):
            message
        }
    }
}
