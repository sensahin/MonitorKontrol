import CoreGraphics
import Darwin
import Foundation

enum DisplayControlError: LocalizedError, Equatable, Sendable {
    case frameworkUnavailable
    case operationFailed(String)
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            "The macOS display-control service is unavailable."
        case let .operationFailed(message):
            message
        case .displayNotFound:
            "The display is no longer connected."
        }
    }
}

final class NativeBrightnessController {
    private typealias GetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getBrightnessFunction: GetBrightnessFunction?
    private let setBrightnessFunction: SetBrightnessFunction?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        frameworkHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        if let frameworkHandle {
            if let symbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness") {
                getBrightnessFunction = unsafeBitCast(symbol, to: GetBrightnessFunction.self)
            } else {
                getBrightnessFunction = nil
            }
            if let symbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
                setBrightnessFunction = unsafeBitCast(symbol, to: SetBrightnessFunction.self)
            } else {
                setBrightnessFunction = nil
            }
        } else {
            getBrightnessFunction = nil
            setBrightnessFunction = nil
        }
    }

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }

    func brightness(for displayID: CGDirectDisplayID) throws -> Double {
        guard let getBrightnessFunction else { throw DisplayControlError.frameworkUnavailable }
        var brightness: Float = 1
        let result = getBrightnessFunction(displayID, &brightness)
        guard result == 0 else {
            throw DisplayControlError.operationFailed("macOS could not read native brightness (code \(result)).")
        }
        return Double(brightness).clampedToUnitInterval
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) throws {
        guard let setBrightnessFunction else { throw DisplayControlError.frameworkUnavailable }
        let result = setBrightnessFunction(displayID, Float(brightness.clampedToUnitInterval))
        guard result == 0 else {
            throw DisplayControlError.operationFailed("macOS could not set native brightness (code \(result)).")
        }
    }
}
