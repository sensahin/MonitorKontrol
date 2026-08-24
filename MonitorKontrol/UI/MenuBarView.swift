import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var manager: DisplayManager
    @Environment(\.openSettings) private var openSettings
    @State private var measuredControlHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    if manager.displays.count > 1 {
                        allDisplaysControl
                    }

                    if manager.displays.isEmpty {
                        emptyState
                    } else {
                        ForEach(manager.displays) { display in
                            DisplayControlCard(display: display, manager: manager)
                        }
                    }

                    quickScenes
                }
                .padding(14)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ControlAreaContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            // A ScrollView has no intrinsic ideal height inside MenuBarExtra.
            // Measure its content so AppKit neither collapses the controls nor
            // leaves a fixed empty area when the available controls change.
            .frame(height: resolvedControlHeight)
            .onPreferenceChange(ControlAreaContentHeightKey.self) { height in
                guard height > 0 else { return }
                measuredControlHeight = height
            }

            Divider()
            footer
        }
        .frame(width: 390)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display.2")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("MonitorKontrol")
                    .font(.headline)
                    .accessibilityIdentifier("monitorkontrol-title")
                Text(manager.connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if manager.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    manager.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Detect displays again")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var fallbackControlHeight: CGFloat {
        switch manager.displays.count {
        case 0: 260
        case 1: 320
        default: 460
        }
    }

    private var resolvedControlHeight: CGFloat {
        min(ceil(measuredControlHeight ?? fallbackControlHeight), 540)
    }

    private var allDisplaysControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("All displays", systemImage: "rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(manager.allDisplaysBrightness.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { manager.allDisplaysBrightness },
                    set: { manager.setAllBrightness($0) }
                ),
                in: 0 ... 1
            )
            .accessibilityLabel("All displays brightness")
            .accessibilityIdentifier("all-displays-brightness")
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Displays Found",
            systemImage: "display.trianglebadge.exclamationmark",
            description: Text("Reconnect the display, then detect displays again.")
        )
        .frame(minHeight: 180)
    }

    private var quickScenes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick scenes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !manager.scenes.isEmpty {
                    Text("\(manager.scenes.count) saved")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                QuickSceneButton(title: "Night", symbol: "moon.stars", value: 0.3) {
                    manager.setAllBrightness(0.3)
                }
                QuickSceneButton(title: "Focus", symbol: "sun.max", value: 0.7) {
                    manager.setAllBrightness(0.7)
                }
                QuickSceneButton(title: "Full", symbol: "sun.max.fill", value: 1) {
                    manager.setAllBrightness(1)
                }
            }

            if !manager.scenes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(manager.scenes) { scene in
                            Button {
                                manager.apply(scene: scene)
                            } label: {
                                Label(scene.name, systemImage: scene.symbolName)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")

            Spacer()

            Button("Quit") {
                manager.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ControlAreaContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DisplayControlCard: View {
    let display: DisplayDevice
    @ObservedObject var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 19))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(display.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if display.isMain {
                            Text("MAIN")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.14), in: Capsule())
                        }
                    }
                    Label(display.backend.title, systemImage: display.backend.symbolName)
                        .font(.caption2)
                        .foregroundStyle(backendColor)
                }

                Spacer()

                Text(display.brightness.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 9) {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { manager.brightness(for: display.id) },
                        set: { manager.setBrightness($0, for: display.id) }
                    ),
                    in: 0 ... 1
                )
                .accessibilityLabel("\(display.name) brightness")
                .accessibilityIdentifier(
                    display.isBuiltIn
                        ? "built-in-brightness"
                        : String(format: "external-brightness-%04X-%04X", display.vendorID, display.productID)
                )
                .disabled(display.backend == .probing || display.backend == .unavailable)
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
            }

            if display.capabilities.contrast, let contrast = display.contrast {
                compactControl(
                    title: "Contrast",
                    symbol: "circle.lefthalf.filled",
                    value: contrast,
                    setValue: { manager.setContrast($0, for: display.id) }
                )
            }

            if display.capabilities.volume, let volume = display.volume {
                compactControl(
                    title: "Volume",
                    symbol: "speaker.wave.2.fill",
                    value: volume,
                    setValue: { manager.setVolume($0, for: display.id) }
                )
            }

            if let lastError = display.lastError {
                Label(lastError, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(display.statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.45))
        }
    }

    private var backendColor: Color {
        switch display.backend {
        case .native, .ddc: .green
        case .software: .blue
        case .probing: .secondary
        case .unavailable: .orange
        }
    }

    private func compactControl(
        title: String,
        symbol: String,
        value: Double,
        setValue: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { value }, set: setValue), in: 0 ... 1)
            Text(value.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct QuickSceneButton: View {
    let title: String
    let symbol: String
    let value: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title)
                    .font(.caption)
                Text(value.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
    }
}
