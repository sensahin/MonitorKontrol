import Foundation

struct DisplayScene: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var symbolName: String
    var brightnessByDisplayID: [String: Double]
    var fallbackBrightness: Double

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "slider.horizontal.3",
        brightnessByDisplayID: [String: Double],
        fallbackBrightness: Double
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.brightnessByDisplayID = brightnessByDisplayID
        self.fallbackBrightness = fallbackBrightness.clampedToUnitInterval
    }
}

extension Double {
    var clampedToUnitInterval: Double { min(max(self, 0), 1) }
}
