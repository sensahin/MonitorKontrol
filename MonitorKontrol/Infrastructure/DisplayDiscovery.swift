import AppKit
import CoreGraphics
import Foundation

@MainActor
struct DisplayDiscovery {
    private let coreDisplay = CoreDisplayRuntime()

    func discover() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }

        let screenNames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            screen.monitorKontrolDisplayID.map { ($0, screen.localizedName) }
        })

        let discovered = displayIDs.prefix(Int(count)).map { displayID in
            let mode = CGDisplayCopyDisplayMode(displayID)
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)
                .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)
            let builtIn = CGDisplayIsBuiltin(displayID) != 0
            let displayLocation = builtIn
                ? nil
                : (try? coreDisplay.displayInfo(for: displayID))?["IODisplayLocation"] as? String

            return DisplayDescriptor(
                displayID: displayID,
                persistentID: DisplayIdentity.persistentID(
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serialNumber,
                    displayUUID: uuid,
                    displayLocation: displayLocation,
                    fallbackDisplayID: displayID
                ),
                name: screenNames[displayID] ?? (builtIn ? "Built-in Display" : "Display \(displayID)"),
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber,
                isBuiltIn: builtIn,
                isMain: CGDisplayIsMain(displayID) != 0,
                pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(displayID),
                pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID),
                refreshRate: mode?.refreshRate ?? 0
            )
        }

        let identityCounts = Dictionary(grouping: discovered, by: \.persistentID).mapValues(\.count)
        return discovered.map { descriptor in
            guard identityCounts[descriptor.persistentID, default: 0] > 1 else { return descriptor }
            return DisplayDescriptor(
                displayID: descriptor.displayID,
                persistentID: "\(descriptor.persistentID)-CG-\(descriptor.displayID)",
                name: descriptor.name,
                vendorID: descriptor.vendorID,
                productID: descriptor.productID,
                serialNumber: descriptor.serialNumber,
                isBuiltIn: descriptor.isBuiltIn,
                isMain: descriptor.isMain,
                pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight,
                refreshRate: descriptor.refreshRate
            )
        }
        .sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            if $0.isBuiltIn != $1.isBuiltIn { return !$0.isBuiltIn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

extension NSScreen {
    var monitorKontrolDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
