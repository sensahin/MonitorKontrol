import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [DisplayDevice] = []
    @Published private(set) var scenes: [DisplayScene]
    @Published private(set) var isRefreshing = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var showOnlyWithExternalDisplay: Bool
    @Published private(set) var allowSoftwareFallback: Bool
    @Published var isMenuBarInserted = true
    @Published private(set) var settingsMessage: String?

    private let discovery = DisplayDiscovery()
    private let nativeBrightness = NativeBrightnessController()
    private let ddcTransport = DDCTransport()
    private let softwareDimming = SoftwareDimmingController()
    private let preferences: PreferencesStore
    private let loginItemController = LoginItemController()

    private var ddcEndpoints: [String: DDCDisplayEndpoint] = [:]
    private var ddcMaximums: [String: [DDCVCPCode: UInt16]] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var writeTaskTokens: [String: UUID] = [:]
    private var refreshGeneration = 0
    private var systemChangesRegistered = false
    private var hasShutDown = false

    init(preferences: PreferencesStore = PreferencesStore()) {
        self.preferences = preferences
        scenes = preferences.loadScenes()
        showOnlyWithExternalDisplay = ProcessInfo.processInfo.environment["MONITORKONTROL_UI_QA"] == "1"
            ? false
            : preferences.showOnlyWithExternalDisplay
        allowSoftwareFallback = preferences.allowSoftwareFallback
        launchAtLogin = loginItemController.isRegistered
        launchAtLoginRequiresApproval = loginItemController.requiresApproval

        // The gated hardware integration test owns the DDC route exclusively.
        // Keeping the app host idle prevents two transports from interleaving
        // packets while the test captures and restores the real display state.
        if ProcessInfo.processInfo.environment["MONITORKONTROL_HARDWARE_QA"] == "1" {
            isMenuBarInserted = false
        } else {
            registerForSystemChanges()
            refreshDisplays()
        }
    }

    deinit {
        refreshTask?.cancel()
        writeTasks.values.forEach { $0.cancel() }
        if systemChangesRegistered {
            CGDisplayRemoveReconfigurationCallback(
                monitorKontrolDisplayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var externalDisplayCount: Int { displays.lazy.filter { !$0.isBuiltIn }.count }
    var hasExternalDisplay: Bool { externalDisplayCount > 0 }

    var connectionSummary: String {
        switch displays.count {
        case 0: "No displays detected"
        case 1: displays[0].kindTitle
        default: "\(displays.count) displays · \(externalDisplayCount) external"
        }
    }

    var allDisplaysBrightness: Double {
        let controlled = displays.filter { $0.backend != .unavailable && $0.backend != .probing }
        guard !controlled.isEmpty else { return 0 }
        return controlled.map(\.brightness).reduce(0, +) / Double(controlled.count)
    }

    func brightness(for persistentID: String) -> Double {
        displays.first(where: { $0.id == persistentID })?.brightness ?? 0
    }

    func refreshDisplays() {
        guard !hasShutDown else { return }
        cancelAllDDCWrites()
        ddcTransport.cancelPendingWrites()
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        let descriptors = discovery.discover()
        let previousByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        displays = descriptors.map { descriptor in
            let saved = preferences.settings(for: descriptor.persistentID)
            var device = DisplayDevice(
                descriptor: descriptor,
                brightness: previousByID[descriptor.persistentID]?.brightness ?? saved.brightness
            )
            if descriptor.isBuiltIn {
                configureNativeDisplay(&device)
            } else if saved.backendPreference == .software {
                configureSoftwareFallback(&device, reason: "Software dimming is forced in display settings.")
            }
            return device
        }

        let validIDs = Set(descriptors.map(\.displayID))
        let validPersistentIDs = Set(descriptors.map(\.persistentID))
        softwareDimming.removeDisconnectedDisplays(validDisplayIDs: validIDs)
        softwareDimming.updateShadeFrames()
        ddcEndpoints = ddcEndpoints.filter {
            validPersistentIDs.contains($0.key) && validIDs.contains($0.value.displayID)
        }
        ddcMaximums = ddcMaximums.filter { validPersistentIDs.contains($0.key) }
        updateMenuVisibility()

        let external = descriptors.filter { !$0.isBuiltIn }
        guard !external.isEmpty else {
            isRefreshing = false
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.probeExternalDisplays(external, generation: generation)
        }
    }

    func probeDisplay(id _: String) {
        // Rediscovery is intentional: IOAVService handles must never survive a reconnect.
        refreshDisplays()
    }

    func setBrightness(_ value: Double, for persistentID: String) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }) else { return }
        let currentBackend = displays[index].backend
        guard currentBackend != .probing, currentBackend != .unavailable else { return }

        let clamped = value.clampedToUnitInterval
        displays[index].brightness = clamped
        displays[index].lastError = nil

        var stored = preferences.settings(for: persistentID)
        stored.brightness = clamped
        preferences.save(stored, for: persistentID)

        let display = displays[index]
        switch display.backend {
        case .native:
            do {
                try nativeBrightness.setBrightness(clamped, for: display.displayID)
                displays[index].statusDetail = "MacBook backlight · native macOS control"
            } catch {
                record(error, for: persistentID)
            }

        case .ddc:
            guard let endpoint = ddcEndpoints[persistentID] else {
                record(DisplayControlError.displayNotFound, for: persistentID)
                return
            }
            let maximum = ddcMaximums[persistentID]?[.brightness] ?? 100
            let hardwareValue = UInt16((clamped * Double(maximum)).rounded())
            enqueueDDCWrite(.brightness, value: hardwareValue, endpoint: endpoint, displayID: persistentID)

        case .software:
            do {
                try softwareDimming.setBrightness(clamped, for: display.displayID)
                displays[index].statusDetail = "Click-through software shade · hardware unchanged"
            } catch {
                record(error, for: persistentID)
            }

        case .probing, .unavailable:
            break
        }
    }

    func setAllBrightness(_ value: Double) {
        for display in displays where display.backend != .probing && display.backend != .unavailable {
            setBrightness(value, for: display.id)
        }
    }

    func setContrast(_ value: Double, for persistentID: String) {
        setDDCValue(value, code: .contrast, for: persistentID) { display, normalized in
            display.contrast = normalized
        }
    }

    func setVolume(_ value: Double, for persistentID: String) {
        setDDCValue(value, code: .speakerVolume, for: persistentID) { display, normalized in
            display.volume = normalized
        }
    }

    func isSoftwareForced(for persistentID: String) -> Bool {
        preferences.settings(for: persistentID).backendPreference == .software
    }

    func setSoftwareForced(_ forced: Bool, for persistentID: String) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }), !displays[index].isBuiltIn else {
            return
        }
        guard !forced || allowSoftwareFallback else {
            settingsMessage = "Enable ‘Allow software dimming’ in General settings before forcing it for a display."
            return
        }
        var stored = preferences.settings(for: persistentID)
        stored.backendPreference = forced ? .software : .automatic
        preferences.save(stored, for: persistentID)

        let requestedBrightness = displays[index].brightness
        let displayID = displays[index].displayID
        cancelDDCWrites(for: persistentID)

        if forced {
            // Rediscovery invalidates the transport generation for every old
            // endpoint. This makes a task that raced with cancellation stale
            // before the software shade is applied.
            refreshDisplays()
            setBrightness(requestedBrightness, for: persistentID)
        } else {
            try? softwareDimming.setBrightness(1, for: displayID)
            refreshDisplays()
        }
    }

    func setShowOnlyWithExternalDisplay(_ enabled: Bool) {
        showOnlyWithExternalDisplay = enabled
        preferences.showOnlyWithExternalDisplay = enabled
        updateMenuVisibility()
    }

    func setAllowSoftwareFallback(_ enabled: Bool) {
        allowSoftwareFallback = enabled
        preferences.allowSoftwareFallback = enabled
        if !enabled { softwareDimming.restoreAll() }
        refreshDisplays()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            launchAtLogin = loginItemController.isRegistered
            launchAtLoginRequiresApproval = loginItemController.requiresApproval
            settingsMessage = launchAtLoginRequiresApproval
                ? "Login launch needs approval in System Settings › General › Login Items & Extensions."
                : nil
        } catch {
            launchAtLogin = loginItemController.isRegistered
            launchAtLoginRequiresApproval = loginItemController.requiresApproval
            settingsMessage = error.localizedDescription
        }
    }

    func saveCurrentScene(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displays.isEmpty else { return }
        let values = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.brightness) })
        let scene = DisplayScene(
            name: name,
            brightnessByDisplayID: values,
            fallbackBrightness: allDisplaysBrightness
        )
        scenes.append(scene)
        preferences.saveScenes(scenes)
    }

    func apply(scene: DisplayScene) {
        for display in displays {
            setBrightness(scene.brightnessByDisplayID[display.id] ?? scene.fallbackBrightness, for: display.id)
        }
    }

    func delete(scene: DisplayScene) {
        scenes.removeAll { $0.id == scene.id }
        preferences.saveScenes(scenes)
    }

    var diagnosticReport: String {
        var lines = [
            "MonitorKontrol 1.0 (1)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architectureName)",
            "App Sandbox: disabled (required for Apple-silicon DDC)",
            "Displays: \(displays.count)",
            "",
        ]

        for (offset, display) in displays.enumerated() {
            let role = display.isBuiltIn ? "built-in" : "external"
            let mainSuffix = display.isMain ? ", main" : ""
            lines.append("Display \(offset + 1) (\(role)\(mainSuffix))")
            lines.append("  vendor/product: \(String(format: "%04X/%04X", display.vendorID, display.productID))")
            lines.append("  mode: \(display.resolutionDescription)")
            lines.append("  backend: \(display.backend.title)")
            lines.append("  status: \(display.statusDetail)")
            lines.append("  brightness: \(display.brightness.formatted(.percent.precision(.fractionLength(1))))")
            lines.append("  contrast: \(display.contrast.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "not detected")")
            lines.append("  volume: \(display.volume.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "not detected")")
            if let error = display.lastError { lines.append("  last error: \(error)") }
            lines.append("")
        }

        lines.append("Unique display identifiers and serial numbers are redacted.")
        lines.append("Private display APIs can change after macOS updates; capabilities are probed at runtime.")
        return lines.joined(separator: "\n")
    }

    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
        settingsMessage = "Diagnostic report copied."
    }

    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        refreshTask?.cancel()
        cancelAllDDCWrites()
        ddcTransport.cancelPendingWrites()
        softwareDimming.restoreAll()
    }

    private func configureNativeDisplay(_ display: inout DisplayDevice) {
        do {
            display.brightness = try nativeBrightness.brightness(for: display.displayID)
            softwareDimming.removeShade(for: display.displayID)
            display.backend = .native
            display.statusDetail = "MacBook backlight · native macOS control"
        } catch {
            if allowSoftwareFallback {
                configureSoftwareFallback(&display, reason: "Native backlight control was unavailable.")
            } else {
                display.backend = .unavailable
                display.statusDetail = "Native brightness is unavailable on this macOS version."
                display.lastError = error.localizedDescription
            }
        }
    }

    private func configureSoftwareFallback(_ display: inout DisplayDevice, reason: String) {
        guard allowSoftwareFallback else {
            display.backend = .unavailable
            display.statusDetail = "No supported control method was detected."
            return
        }
        display.backend = .software
        display.capabilities = DisplayCapabilities()
        let applied = softwareDimming.brightnessApplied(to: display.displayID)
        display.brightness = applied ?? 1
        display.statusDetail = reason
        let savedTarget = preferences.settings(for: display.id).brightness
        if applied == nil, savedTarget < 0.995 {
            display.statusDetail += " Saved \(savedTarget.formatted(.percent.precision(.fractionLength(0)))) is not applied."
        }
        display.lastError = nil
    }

    private func probeExternalDisplays(_ descriptors: [DisplayDescriptor], generation: Int) async {
        let automaticDescriptors = descriptors.filter {
            preferences.settings(for: $0.persistentID).backendPreference == .automatic
        }

        guard !automaticDescriptors.isEmpty else {
            if generation == refreshGeneration { isRefreshing = false }
            return
        }

        do {
            let endpoints = try await ddcTransport.discover(displayIDs: automaticDescriptors.map(\.displayID))
            guard !Task.isCancelled, generation == refreshGeneration else { return }

            for descriptor in automaticDescriptors {
                guard let endpoint = endpoints.first(where: { $0.displayID == descriptor.displayID }) else {
                    applyExternalFallback(to: descriptor.persistentID, reason: "No Apple-silicon DDC route was found for this connection.")
                    continue
                }

                ddcEndpoints[descriptor.persistentID] = endpoint
                let results = await ddcTransport.probe(
                    [.brightness, .contrast, .speakerVolume],
                    on: endpoint
                )
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                applyProbeResults(results, endpoint: endpoint, persistentID: descriptor.persistentID)
            }
        } catch {
            guard generation == refreshGeneration else { return }
            for descriptor in automaticDescriptors {
                applyExternalFallback(to: descriptor.persistentID, reason: error.localizedDescription)
            }
        }

        if generation == refreshGeneration { isRefreshing = false }
    }

    private func applyProbeResults(
        _ results: [DDCProbeResult],
        endpoint: DDCDisplayEndpoint,
        persistentID: String
    ) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }) else { return }
        let values = Dictionary(uniqueKeysWithValues: results.compactMap { result in
            result.value.map { ($0.code, $0) }
        })

        guard let brightness = values[.brightness], brightness.maximum > 0, !brightness.isMomentary else {
            ddcEndpoints.removeValue(forKey: persistentID)
            let brightnessFailure = results.first(where: { $0.code == .brightness })?.failure
            applyExternalFallback(
                to: persistentID,
                reason: brightnessFailure?.localizedDescription
                    ?? "The display answered on the connection but did not return DDC brightness."
            )
            return
        }

        let contrast = values[.contrast].flatMap { $0.maximum > 0 && !$0.isMomentary ? $0 : nil }
        let volume = values[.speakerVolume].flatMap { $0.maximum > 0 && !$0.isMomentary ? $0 : nil }

        ddcEndpoints[persistentID] = endpoint
        ddcMaximums[persistentID] = [
            .brightness: brightness.maximum,
            .contrast: contrast?.maximum,
            .speakerVolume: volume?.maximum,
        ].compactMapValues { $0 }
        softwareDimming.removeShade(for: displays[index].displayID)
        displays[index].backend = .ddc
        displays[index].brightness = normalized(brightness)
        displays[index].contrast = contrast.map(normalized)
        displays[index].volume = volume.map(normalized)
        displays[index].capabilities = DisplayCapabilities(
            contrast: contrast != nil,
            volume: volume != nil
        )
        displays[index].statusDetail = "Verified DDC readback · \(endpoint.route)"
        displays[index].lastError = nil

        var stored = preferences.settings(for: persistentID)
        stored.brightness = displays[index].brightness
        preferences.save(stored, for: persistentID)
    }

    private func applyExternalFallback(to persistentID: String, reason: String) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }) else { return }
        ddcEndpoints.removeValue(forKey: persistentID)
        ddcMaximums.removeValue(forKey: persistentID)
        configureSoftwareFallback(&displays[index], reason: reason)
    }

    private func setDDCValue(
        _ value: Double,
        code: DDCVCPCode,
        for persistentID: String,
        update: (inout DisplayDevice, Double) -> Void
    ) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }),
              displays[index].backend == .ddc,
              let endpoint = ddcEndpoints[persistentID]
        else { return }

        let normalized = value.clampedToUnitInterval
        update(&displays[index], normalized)
        displays[index].lastError = nil
        let maximum = ddcMaximums[persistentID]?[code] ?? 100
        let hardwareValue = UInt16((normalized * Double(maximum)).rounded())
        enqueueDDCWrite(code, value: hardwareValue, endpoint: endpoint, displayID: persistentID)
    }

    private func enqueueDDCWrite(
        _ code: DDCVCPCode,
        value: UInt16,
        endpoint: DDCDisplayEndpoint,
        displayID: String
    ) {
        guard !hasShutDown else { return }
        let taskKey = "\(displayID)-\(code.rawValue)"
        writeTasks[taskKey]?.cancel()
        let token = UUID()
        writeTaskTokens[taskKey] = token
        writeTasks[taskKey] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.writeTaskTokens[taskKey] == token {
                    self.writeTasks.removeValue(forKey: taskKey)
                    self.writeTaskTokens.removeValue(forKey: taskKey)
                }
            }
            do {
                try Task.checkCancellation()
                try await self.ddcTransport.write(code, value: value, to: endpoint, coalescing: true)
                guard !Task.isCancelled else { return }
                self.clearError(for: displayID)
            } catch {
                guard !Task.isCancelled else { return }
                self.record(error, for: displayID)
            }
        }
    }

    private func cancelDDCWrites(for displayID: String) {
        for code in [DDCVCPCode.brightness, .contrast, .speakerVolume] {
            let taskKey = "\(displayID)-\(code.rawValue)"
            writeTasks.removeValue(forKey: taskKey)?.cancel()
            writeTaskTokens.removeValue(forKey: taskKey)
        }
    }

    private func cancelAllDDCWrites() {
        writeTasks.values.forEach { $0.cancel() }
        writeTasks.removeAll()
        writeTaskTokens.removeAll()
    }

    private func normalized(_ value: DDCVCPValue) -> Double {
        guard value.maximum > 0 else { return 0 }
        return (Double(value.current) / Double(value.maximum)).clampedToUnitInterval
    }

    private func record(_ error: Error, for persistentID: String) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }) else { return }
        displays[index].lastError = error.localizedDescription
    }

    private func clearError(for persistentID: String) {
        guard let index = displays.firstIndex(where: { $0.id == persistentID }) else { return }
        displays[index].lastError = nil
    }

    private func registerForSystemChanges() {
        systemChangesRegistered = CGDisplayRegisterReconfigurationCallback(
            monitorKontrolDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        ) == .success

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefresh()
                }
            }
        }

        let terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        applicationObservers.append(terminationObserver)
    }

    fileprivate func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.refreshDisplays()
        }
    }

    private func updateMenuVisibility() {
        let shouldInsert = !showOnlyWithExternalDisplay || hasExternalDisplay
        guard isMenuBarInserted != shouldInsert else { return }
        isMenuBarInserted = shouldInsert
    }

    private var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private func monitorKontrolDisplayReconfigurationCallback(
    _: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in manager.scheduleRefresh() }
}
