import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: DisplayManager

    var body: some View {
        TabView {
            GeneralSettingsView(manager: manager)
                .tabItem { Label("General", systemImage: "gearshape") }

            DisplaySettingsView(manager: manager)
                .tabItem { Label("Displays", systemImage: "display.2") }

            SceneSettingsView(manager: manager)
                .tabItem { Label("Scenes", systemImage: "slider.horizontal.3") }

            DiagnosticsView(manager: manager)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(20)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var manager: DisplayManager

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch MonitorKontrol at login",
                    isOn: Binding(
                        get: { manager.launchAtLogin },
                        set: { manager.setLaunchAtLogin($0) }
                    )
                )
                if manager.launchAtLoginRequiresApproval {
                    Label(
                        "Approve MonitorKontrol in System Settings › General › Login Items & Extensions.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Toggle(
                    "Show menu-bar icon only when an external display is connected",
                    isOn: Binding(
                        get: { manager.showOnlyWithExternalDisplay },
                        set: { manager.setShowOnlyWithExternalDisplay($0) }
                    )
                )
            }

            Section("Fallback") {
                Toggle(
                    "Allow software dimming when hardware control is unavailable",
                    isOn: Binding(
                        get: { manager.allowSoftwareFallback },
                        set: { manager.setAllowSoftwareFallback($0) }
                    )
                )
                Text("Software dimming uses a click-through shade and is never applied automatically at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = manager.settingsMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettingsView: View {
    @ObservedObject var manager: DisplayManager

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(manager.displays) { display in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(
                                display.name,
                                systemImage: display.isBuiltIn ? "laptopcomputer" : "display"
                            )
                            .font(.headline)
                            Spacer()
                            Text(display.backend.title)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }

                        LabeledContent("Type", value: display.kindTitle)
                        LabeledContent("Mode", value: display.resolutionDescription)
                        LabeledContent(
                            "Hardware ID",
                            value: String(
                                format: "%04X:%04X · %08X",
                                display.vendorID,
                                display.productID,
                                display.serialNumber
                            )
                        )
                        LabeledContent("Control", value: display.statusDetail)

                        if !display.isBuiltIn {
                            Toggle(
                                "Force software dimming for this display",
                                isOn: Binding(
                                    get: { manager.isSoftwareForced(for: display.id) },
                                    set: { manager.setSoftwareForced($0, for: display.id) }
                                )
                            )
                            .disabled(!manager.allowSoftwareFallback)
                            .help(
                                manager.allowSoftwareFallback
                                    ? "Use a click-through shade instead of hardware DDC."
                                    : "Enable software dimming in General settings before forcing it for a display."
                            )
                        }

                        HStack {
                            Spacer()
                            Button("Run read-only probe") {
                                manager.probeDisplay(id: display.id)
                            }
                        }
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

private struct SceneSettingsView: View {
    @ObservedObject var manager: DisplayManager
    @State private var sceneName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save the current per-display brightness values as a reusable scene.")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Scene name", text: $sceneName)
                Button("Save Current") {
                    manager.saveCurrentScene(named: sceneName)
                    sceneName = ""
                }
                .disabled(sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                ForEach(manager.scenes) { scene in
                    HStack {
                        Label(scene.name, systemImage: scene.symbolName)
                        Spacer()
                        Button("Apply") { manager.apply(scene: scene) }
                        Button(role: .destructive) {
                            manager.delete(scene: scene)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if manager.scenes.isEmpty {
                    ContentUnavailableView(
                        "No Saved Scenes",
                        systemImage: "slider.horizontal.3",
                        description: Text("Set each display, name the scene, and save it here.")
                    )
                }
            }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Control diagnostics")
                        .font(.headline)
                    Text("Unique display identifiers and serial numbers are redacted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { manager.refreshDisplays() }
                Button("Copy Report") { manager.copyDiagnosticReport() }
            }

            ScrollView {
                Text(manager.diagnosticReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
