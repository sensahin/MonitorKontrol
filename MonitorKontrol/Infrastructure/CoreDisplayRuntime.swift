import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit

/// Resolves the undocumented CoreDisplay entry points at runtime so a macOS
/// update can disable hardware DDC gracefully instead of preventing launch.
final class CoreDisplayRuntime {
    typealias AVService = CFTypeRef

    private typealias CreateServiceFunction = @convention(c) (
        CFAllocator?,
        io_service_t
    ) -> Unmanaged<CFTypeRef>?
    private typealias ReadI2CFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer,
        UInt32
    ) -> IOReturn
    private typealias WriteI2CFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer,
        UInt32
    ) -> IOReturn
    private typealias DisplayInfoFunction = @convention(c) (
        CGDirectDisplayID
    ) -> Unmanaged<CFDictionary>?

    private static let frameworkPath =
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let createServiceFunction: CreateServiceFunction?
    private let readI2CFunction: ReadI2CFunction?
    private let writeI2CFunction: WriteI2CFunction?
    private let displayInfoFunction: DisplayInfoFunction?

    init() {
        let handle = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL)
        frameworkHandle = handle
        createServiceFunction = Self.loadFunction("IOAVServiceCreateWithService", from: handle)
        readI2CFunction = Self.loadFunction("IOAVServiceReadI2C", from: handle)
        writeI2CFunction = Self.loadFunction("IOAVServiceWriteI2C", from: handle)
        displayInfoFunction = Self.loadFunction(
            "CoreDisplay_DisplayCreateInfoDictionary",
            from: handle
        )
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    func requireDDCSupport() throws {
        guard frameworkHandle != nil else {
            throw DDCTransportError.privateAPIUnavailable(
                "CoreDisplay.framework could not be loaded"
            )
        }

        let missingSymbols = [
            ("IOAVServiceCreateWithService", createServiceFunction != nil),
            ("IOAVServiceReadI2C", readI2CFunction != nil),
            ("IOAVServiceWriteI2C", writeI2CFunction != nil),
            ("CoreDisplay_DisplayCreateInfoDictionary", displayInfoFunction != nil)
        ]
        .compactMap { name, isAvailable in isAvailable ? nil : name }

        guard missingSymbols.isEmpty else {
            throw DDCTransportError.privateAPIUnavailable(
                "missing CoreDisplay symbol(s): \(missingSymbols.joined(separator: ", "))"
            )
        }
    }

    func createService(for registryEntry: io_service_t) throws -> AVService? {
        guard let createServiceFunction else {
            throw missingSymbol("IOAVServiceCreateWithService")
        }
        return createServiceFunction(kCFAllocatorDefault, registryEntry)?.takeRetainedValue()
    }

    func readI2C(
        service: AVService,
        chipAddress: UInt32,
        dataAddress: UInt32,
        outputBuffer: UnsafeMutableRawPointer,
        outputBufferSize: UInt32
    ) throws -> IOReturn {
        guard let readI2CFunction else {
            throw missingSymbol("IOAVServiceReadI2C")
        }
        return readI2CFunction(
            service,
            chipAddress,
            dataAddress,
            outputBuffer,
            outputBufferSize
        )
    }

    func writeI2C(
        service: AVService,
        chipAddress: UInt32,
        dataAddress: UInt32,
        inputBuffer: UnsafeMutableRawPointer,
        inputBufferSize: UInt32
    ) throws -> IOReturn {
        guard let writeI2CFunction else {
            throw missingSymbol("IOAVServiceWriteI2C")
        }
        return writeI2CFunction(
            service,
            chipAddress,
            dataAddress,
            inputBuffer,
            inputBufferSize
        )
    }

    func displayInfo(for displayID: CGDirectDisplayID) throws -> NSDictionary? {
        guard let displayInfoFunction else {
            throw missingSymbol("CoreDisplay_DisplayCreateInfoDictionary")
        }
        return displayInfoFunction(displayID)?.takeRetainedValue() as NSDictionary?
    }

    private func missingSymbol(_ name: String) -> DDCTransportError {
        .privateAPIUnavailable("missing CoreDisplay symbol: \(name)")
    }

    private static func loadFunction<Function>(
        _ name: String,
        from handle: UnsafeMutableRawPointer?
    ) -> Function? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }
}
