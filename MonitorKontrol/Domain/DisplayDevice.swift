import CoreGraphics
import Foundation

enum DisplayControlBackend: Sendable {
    case probing
    case native
    case ddc
    case software
    case unavailable

    var title: String {
        switch self {
        case .probing: "Checking"
        case .native: "Native"
        case .ddc: "Hardware DDC"
        case .software: "Software"
        case .unavailable: "Unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .probing: "hourglass"
        case .native: "apple.logo"
        case .ddc: "cable.connector"
        case .software: "circle.lefthalf.filled"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

struct DisplayCapabilities: Sendable {
    var contrast = false
    var volume = false
}

struct DisplayDescriptor: Sendable {
    let displayID: CGDirectDisplayID
    let persistentID: String
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let isBuiltIn: Bool
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
}

struct DisplayDevice: Identifiable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let isBuiltIn: Bool
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var brightness: Double
    var contrast: Double?
    var volume: Double?
    var backend: DisplayControlBackend
    var capabilities: DisplayCapabilities
    var statusDetail: String
    var lastError: String?

    init(
        descriptor: DisplayDescriptor,
        brightness: Double = 1,
        backend: DisplayControlBackend = .probing,
        capabilities: DisplayCapabilities = .init(),
        statusDetail: String = "Detecting control method"
    ) {
        id = descriptor.persistentID
        displayID = descriptor.displayID
        name = descriptor.name
        vendorID = descriptor.vendorID
        productID = descriptor.productID
        serialNumber = descriptor.serialNumber
        isBuiltIn = descriptor.isBuiltIn
        isMain = descriptor.isMain
        pixelWidth = descriptor.pixelWidth
        pixelHeight = descriptor.pixelHeight
        refreshRate = descriptor.refreshRate
        self.brightness = brightness
        contrast = nil
        volume = nil
        self.backend = backend
        self.capabilities = capabilities
        self.statusDetail = statusDetail
        lastError = nil
    }

    var kindTitle: String { isBuiltIn ? "Built-in display" : "External display" }

    var resolutionDescription: String {
        let rate = refreshRate > 0 ? " @ \(Int(refreshRate.rounded())) Hz" : ""
        return "\(pixelWidth) × \(pixelHeight)\(rate)"
    }
}

enum DisplayIdentity {
    static let placeholderSerials: Set<UInt32> = [0, 0x01010101, UInt32.max]

    static func persistentID(
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32,
        displayUUID: String?,
        displayLocation: String? = nil,
        fallbackDisplayID: CGDirectDisplayID
    ) -> String {
        let prefix = String(format: "%04X-%04X", vendorID, productID)
        if !placeholderSerials.contains(serialNumber) {
            return "\(prefix)-\(String(format: "%08X", serialNumber))"
        }
        if let displayLocation, !displayLocation.isEmpty {
            return "\(prefix)-LOCATION-\(stableLocationToken(displayLocation))"
        }
        if let displayUUID, !displayUUID.isEmpty {
            return "\(prefix)-\(displayUUID.uppercased())"
        }
        return "\(prefix)-DISPLAY-\(fallbackDisplayID)"
    }

    private static func stableLocationToken(_ location: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in location.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llX", hash)
    }
}
