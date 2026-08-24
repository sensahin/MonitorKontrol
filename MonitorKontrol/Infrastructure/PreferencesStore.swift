import Foundation

enum DisplayBackendPreference: String, Codable, Sendable {
    case automatic
    case software
}

struct StoredDisplaySettings: Codable, Equatable, Sendable {
    var brightness: Double = 1
    var backendPreference: DisplayBackendPreference = .automatic
}

final class PreferencesStore {
    private enum Key {
        static let displaySettings = "displaySettings.v1"
        static let scenes = "scenes.v1"
        static let showOnlyWithExternalDisplay = "showOnlyWithExternalDisplay"
        static let allowSoftwareFallback = "allowSoftwareFallback"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showOnlyWithExternalDisplay: true,
            Key.allowSoftwareFallback: true,
        ])
    }

    var showOnlyWithExternalDisplay: Bool {
        get { defaults.bool(forKey: Key.showOnlyWithExternalDisplay) }
        set { defaults.set(newValue, forKey: Key.showOnlyWithExternalDisplay) }
    }

    var allowSoftwareFallback: Bool {
        get { defaults.bool(forKey: Key.allowSoftwareFallback) }
        set { defaults.set(newValue, forKey: Key.allowSoftwareFallback) }
    }

    func settings(for displayID: String) -> StoredDisplaySettings {
        allDisplaySettings()[displayID] ?? StoredDisplaySettings()
    }

    func save(_ settings: StoredDisplaySettings, for displayID: String) {
        var stored = allDisplaySettings()
        stored[displayID] = settings
        save(stored, key: Key.displaySettings)
    }

    func loadScenes() -> [DisplayScene] {
        load([DisplayScene].self, key: Key.scenes) ?? []
    }

    func saveScenes(_ scenes: [DisplayScene]) {
        save(scenes, key: Key.scenes)
    }

    private func allDisplaySettings() -> [String: StoredDisplaySettings] {
        load([String: StoredDisplaySettings].self, key: Key.displaySettings) ?? [:]
    }

    private func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
