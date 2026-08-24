//
//  DDCTransport.swift
//  MonitorKontrol
//
//  Portions of the DDC packet framing and Apple Silicon IORegistry/
//  DCPAVServiceProxy routing are adapted from the MIT-licensed m1ddc and
//  MonitorControl projects. MonitorKontrol's serialization, coalescing,
//  cancellation, generation tracking, and error handling are original.
//  See THIRD_PARTY_NOTICES.md for licenses and pinned source revisions.
//
import CoreGraphics
import Foundation
import IOKit

struct DDCVCPCode: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let brightness = Self(rawValue: 0x10)
    static let contrast = Self(rawValue: 0x12)
    static let speakerVolume = Self(rawValue: 0x62)
}

struct DDCVCPValue: Sendable {
    let code: DDCVCPCode
    let current: UInt16
    let maximum: UInt16
    let isMomentary: Bool

    var normalized: Double? {
        guard maximum > 0 else { return nil }
        return min(max(Double(current) / Double(maximum), 0), 1)
    }
}

enum DDCTransportRoute: Sendable {
    case standard
    case mcdp29xx
}

struct DDCDisplayEndpoint: Sendable {
    let displayID: CGDirectDisplayID
    let route: DDCTransportRoute
    let generation: UInt64
}

struct DDCProbeResult: Sendable {
    let code: DDCVCPCode
    let value: DDCVCPValue?
    let failure: DDCTransportError?
}

enum DDCTransportError: Error, Equatable, Sendable {
    case unsupportedArchitecture
    case privateAPIUnavailable(String)
    case cancelled
    case staleEndpoint(CGDirectDisplayID)
    case registryTraversalFailed(IOReturn)
    case displayNotDiscovered(CGDirectDisplayID)
    case ioFailure(operation: String, code: IOReturn)
    case malformedReply(String)
    case unsupportedVCPCode(UInt8)
}

extension DDCTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "Hardware DDC is available only on Apple Silicon."
        case let .privateAPIUnavailable(reason):
            return "Hardware DDC is unavailable because \(reason)."
        case .cancelled:
            return "The pending DDC write was cancelled."
        case let .staleEndpoint(displayID):
            return "The DDC connection for display \(displayID) changed; detect displays again."
        case let .registryTraversalFailed(code):
            return "The display registry could not be read (IOKit error \(code))."
        case let .displayNotDiscovered(displayID):
            return "No DDC endpoint is registered for display \(displayID)."
        case let .ioFailure(operation, code):
            return "DDC \(operation) failed (IOKit error \(code))."
        case let .malformedReply(reason):
            return "The display returned an invalid DDC reply: \(reason)."
        case let .unsupportedVCPCode(code):
            return String(format: "The display does not support VCP code 0x%02X.", code)
        }
    }
}

/// Pure DDC/CI framing utilities. They intentionally perform no hardware I/O.
enum DDCPacketCodec {
    static let standardChipAddress: UInt32 = 0x37
    static let mcdp29xxChipAddress: UInt32 = 0xB7
    static let defaultDataAddress: UInt8 = 0x51
    static let ddcSourceAddress: UInt8 = 0x6E
    static let hostReplyAddress: UInt8 = 0x50
    static let replyBufferSize = 12

    static func checksum<S: Sequence>(seed: UInt8, bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    static func readRequest(for code: DDCVCPCode) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code.rawValue]
        packet.append(checksum(seed: ddcSourceAddress, bytes: packet))
        return packet
    }

    static func writeRequest(for code: DDCVCPCode, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x84,
            0x03,
            code.rawValue,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        packet.append(checksum(seed: ddcSourceAddress ^ defaultDataAddress, bytes: packet))
        return packet
    }

    static func parseVCPReply(
        _ buffer: [UInt8],
        expecting code: DDCVCPCode,
        validateChecksum: Bool = true
    ) throws -> DDCVCPValue {
        guard buffer.count >= 11 else {
            throw DDCTransportError.malformedReply("expected at least 11 bytes, received \(buffer.count)")
        }

        let declaredPayloadLength = Int(buffer[1] & 0x7F)
        let packetLength = declaredPayloadLength + 3
        guard packetLength >= 11, packetLength <= buffer.count else {
            throw DDCTransportError.malformedReply("invalid payload length \(declaredPayloadLength)")
        }

        let packet = Array(buffer.prefix(packetLength))
        guard packet[0] == ddcSourceAddress else {
            throw DDCTransportError.malformedReply(
                String(format: "unexpected source address 0x%02X", packet[0])
            )
        }
        guard packet[2] == 0x02 else {
            throw DDCTransportError.malformedReply(
                String(format: "unexpected reply opcode 0x%02X", packet[2])
            )
        }
        guard packet[4] == code.rawValue else {
            throw DDCTransportError.malformedReply(
                String(format: "reply was for VCP 0x%02X, not 0x%02X", packet[4], code.rawValue)
            )
        }
        guard packet[3] == 0 else {
            throw DDCTransportError.unsupportedVCPCode(code.rawValue)
        }

        if validateChecksum {
            let expected = checksum(seed: hostReplyAddress, bytes: packet.dropLast())
            guard expected == packet.last else {
                throw DDCTransportError.malformedReply(
                    String(
                        format: "checksum mismatch (expected 0x%02X, received 0x%02X)",
                        expected,
                        packet.last ?? 0
                    )
                )
            }
        }

        return DDCVCPValue(
            code: code,
            current: UInt16(packet[8]) << 8 | UInt16(packet[9]),
            maximum: UInt16(packet[6]) << 8 | UInt16(packet[7]),
            isMomentary: packet[5] == 0x01
        )
    }
}

/// Serializes all IOAVService calls on a private queue. This keeps DDC traffic
/// off MainActor and prevents sliders/keyboard handlers from talking to the
/// same display in parallel.
final class DDCTransport: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var writeDelay: TimeInterval = 0.010
        var standardReadDelay: TimeInterval = 0.050
        var mcdp29xxReadDelay: TimeInterval = 0.050
        var coalescingInterval: TimeInterval = 0.020
        var writeCycles = 2
        var readAttempts = 3
        var validatesReplyChecksums = true

        init() {}
    }

    private struct ProductIdentity {
        var vendorID: UInt32 = 0
        var productID: UInt32 = 0
        var serialNumber: UInt32 = 0
        var manufacturerID = ""
        var alphanumericSerialNumber = ""
        var name = ""
    }

    private struct DisplayIdentity {
        let displayID: CGDirectDisplayID
        let registryID: UInt64?
        let product: ProductIdentity
    }

    private struct FramebufferSnapshot {
        let registryID: UInt64?
        let product: ProductIdentity
    }

    private struct RegistryCandidate {
        let service: CoreDisplayRuntime.AVService
        let chipAddress: UInt32
        let route: DDCTransportRoute
        let framebuffer: FramebufferSnapshot
    }

    private struct ServiceRecord {
        let service: CoreDisplayRuntime.AVService
        let chipAddress: UInt32
    }

    private struct WriteKey: Hashable {
        let displayID: CGDirectDisplayID
        let code: DDCVCPCode
    }

    private struct PendingWrite {
        let endpoint: DDCDisplayEndpoint
        var value: UInt16
        var continuations: [CheckedContinuation<Void, Error>]
    }

    private let configuration: Configuration
    private let coreDisplay = CoreDisplayRuntime()
    private let ioQueue = DispatchQueue(label: "com.aipower.MonitorKontrol.ddc-transport", qos: .userInitiated)
    private var services: [CGDirectDisplayID: ServiceRecord] = [:]
    private var pendingWrites: [WriteKey: PendingWrite] = [:]
    private var serviceGeneration: UInt64 = 0

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func discover(displayIDs: [CGDirectDisplayID]) async throws -> [DDCDisplayEndpoint] {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[DDCDisplayEndpoint], Error>) in
            ioQueue.async {
                do {
                    continuation.resume(returning: try self.discoverSynchronously(displayIDs: displayIDs))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func read(_ code: DDCVCPCode, from endpoint: DDCDisplayEndpoint) async throws -> DDCVCPValue {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<DDCVCPValue, Error>) in
            ioQueue.async {
                do {
                    continuation.resume(returning: try self.readSynchronously(code, from: endpoint))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write(
        _ code: DDCVCPCode,
        value: UInt16,
        to endpoint: DDCDisplayEndpoint,
        coalescing: Bool = true
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                guard endpoint.generation == self.serviceGeneration else {
                    continuation.resume(
                        throwing: DDCTransportError.staleEndpoint(endpoint.displayID)
                    )
                    return
                }

                let key = WriteKey(displayID: endpoint.displayID, code: code)
                guard coalescing, self.configuration.coalescingInterval > 0 else {
                    self.flushPendingWrite(for: key)
                    do {
                        try self.writeSynchronously(code, value: value, to: endpoint)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                if var pending = self.pendingWrites[key] {
                    pending.value = value
                    pending.continuations.append(continuation)
                    self.pendingWrites[key] = pending
                    return
                }

                self.pendingWrites[key] = PendingWrite(
                    endpoint: endpoint,
                    value: value,
                    continuations: [continuation]
                )
                self.ioQueue.asyncAfter(deadline: .now() + self.configuration.coalescingInterval) {
                    self.flushPendingWrite(for: key)
                }
            }
        }
    }

    /// Synchronously invalidates every issued endpoint and drains queued writes.
    /// The generation bump is the barrier: a task that reaches `write` after
    /// this method returns still carries an old endpoint and cannot touch I/O.
    func cancelPendingWrites() {
        ioQueue.sync {
            self.serviceGeneration &+= 1
            self.services.removeAll()
            self.cancelPendingWritesSynchronously(with: .cancelled)
        }
    }

    /// A capability probe made entirely of Get VCP Feature requests. It never
    /// emits Set VCP Feature packets and therefore cannot change monitor state.
    func probe(
        _ codes: [DDCVCPCode] = [.brightness, .contrast, .speakerVolume],
        on endpoint: DDCDisplayEndpoint
    ) async -> [DDCProbeResult] {
        var results: [DDCProbeResult] = []
        results.reserveCapacity(codes.count)

        for code in codes {
            do {
                let value = try await read(code, from: endpoint)
                results.append(DDCProbeResult(code: code, value: value, failure: nil))
            } catch let error as DDCTransportError {
                results.append(DDCProbeResult(code: code, value: nil, failure: error))
            } catch {
                results.append(
                    DDCProbeResult(
                        code: code,
                        value: nil,
                        failure: .malformedReply(error.localizedDescription)
                    )
                )
            }
        }

        return results
    }
}

private extension DDCTransport {
    func discoverSynchronously(displayIDs: [CGDirectDisplayID]) throws -> [DDCDisplayEndpoint] {
        serviceGeneration &+= 1
        let generation = serviceGeneration
        cancelPendingWritesSynchronously(with: .cancelled)
        services.removeAll()

        #if !arch(arm64)
        throw DDCTransportError.unsupportedArchitecture
        #else
        try coreDisplay.requireDDCSupport()
        let identities = try displayIDs.compactMap { try displayIdentity(for: $0) }
        let candidates = try registryCandidates()
        var unusedCandidateIndices = Set(candidates.indices)
        var discoveredServices: [CGDirectDisplayID: ServiceRecord] = [:]
        var endpoints: [DDCDisplayEndpoint] = []

        for identity in identities {
            let ranked = unusedCandidateIndices
                .map { index in (index, matchScore(identity, candidates[index].framebuffer)) }
                .sorted {
                    if $0.1 == $1.1 { return $0.0 < $1.0 }
                    return $0.1 > $1.1
                }

            guard let best = ranked.first, best.1 >= 12 else { continue }
            let candidate = candidates[best.0]
            unusedCandidateIndices.remove(best.0)

            let endpoint = DDCDisplayEndpoint(
                displayID: identity.displayID,
                route: candidate.route,
                generation: generation
            )

            endpoints.append(endpoint)
            discoveredServices[identity.displayID] = ServiceRecord(
                service: candidate.service,
                chipAddress: candidate.chipAddress
            )
        }

        services = discoveredServices
        return endpoints
        #endif
    }

    func readSynchronously(_ code: DDCVCPCode, from endpoint: DDCDisplayEndpoint) throws -> DDCVCPValue {
        guard endpoint.generation == serviceGeneration else {
            throw DDCTransportError.staleEndpoint(endpoint.displayID)
        }
        guard let record = services[endpoint.displayID] else {
            throw DDCTransportError.displayNotDiscovered(endpoint.displayID)
        }

        let dataAddress = DDCPacketCodec.defaultDataAddress
        let attempts = max(configuration.readAttempts, 1)
        var lastError: Error?

        for _ in 0..<attempts {
            do {
                try writePacket(
                    DDCPacketCodec.readRequest(for: code),
                    record: record,
                    dataAddress: dataAddress
                )

                sleep(
                    record.chipAddress == DDCPacketCodec.mcdp29xxChipAddress
                        ? configuration.mcdp29xxReadDelay
                        : configuration.standardReadDelay
                )

                var reply = [UInt8](repeating: 0, count: DDCPacketCodec.replyBufferSize)
                let result = try reply.withUnsafeMutableBytes { bytes in
                    try coreDisplay.readI2C(
                        service: record.service,
                        chipAddress: record.chipAddress,
                        dataAddress: UInt32(dataAddress),
                        outputBuffer: bytes.baseAddress!,
                        outputBufferSize: UInt32(bytes.count)
                    )
                }
                guard result == kIOReturnSuccess else {
                    throw DDCTransportError.ioFailure(operation: "read", code: result)
                }

                return try DDCPacketCodec.parseVCPReply(
                    reply,
                    expecting: code,
                    validateChecksum: configuration.validatesReplyChecksums
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? DDCTransportError.malformedReply("no reply")
    }

    func writeSynchronously(
        _ code: DDCVCPCode,
        value: UInt16,
        to endpoint: DDCDisplayEndpoint
    ) throws {
        guard endpoint.generation == serviceGeneration else {
            throw DDCTransportError.staleEndpoint(endpoint.displayID)
        }
        guard let record = services[endpoint.displayID] else {
            throw DDCTransportError.displayNotDiscovered(endpoint.displayID)
        }
        let dataAddress = DDCPacketCodec.defaultDataAddress
        try writePacket(
            DDCPacketCodec.writeRequest(for: code, value: value),
            record: record,
            dataAddress: dataAddress
        )
    }

    private func writePacket(_ originalPacket: [UInt8], record: ServiceRecord, dataAddress: UInt8) throws {
        var packet = originalPacket
        for _ in 0..<max(configuration.writeCycles, 1) {
            sleep(configuration.writeDelay)
            let result = try packet.withUnsafeMutableBytes { bytes in
                try coreDisplay.writeI2C(
                    service: record.service,
                    chipAddress: record.chipAddress,
                    dataAddress: UInt32(dataAddress),
                    inputBuffer: bytes.baseAddress!,
                    inputBufferSize: UInt32(bytes.count)
                )
            }
            guard result == kIOReturnSuccess else {
                throw DDCTransportError.ioFailure(operation: "write", code: result)
            }
        }
    }

    private func flushPendingWrite(for key: WriteKey) {
        guard let pending = pendingWrites.removeValue(forKey: key) else { return }
        let result: Result<Void, Error>

        do {
            try writeSynchronously(key.code, value: pending.value, to: pending.endpoint)
            result = .success(())
        } catch {
            result = .failure(error)
        }

        for continuation in pending.continuations {
            continuation.resume(with: result)
        }
    }

    private func cancelPendingWritesSynchronously(with error: DDCTransportError) {
        let writes = Array(pendingWrites.values)
        pendingWrites.removeAll()
        for pending in writes {
            for continuation in pending.continuations {
                continuation.resume(throwing: error)
            }
        }
    }

    private func displayIdentity(for displayID: CGDirectDisplayID) throws -> DisplayIdentity? {
        guard CGDisplayIsBuiltin(displayID) == 0,
              let info = try coreDisplay.displayInfo(for: displayID) else {
            return nil
        }

        let registryPath = info["IODisplayLocation"] as? String ?? ""
        var registryID: UInt64?
        var registryProduct = ProductIdentity()

        if !registryPath.isEmpty {
            let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, registryPath as CFString)
            if adapter != IO_OBJECT_NULL {
                defer { IOObjectRelease(adapter) }
                registryID = registryEntryID(adapter)
                registryProduct = productIdentity(from: adapter)
            }
        }

        var product = registryProduct
        product.vendorID = CGDisplayVendorNumber(displayID)
        product.productID = CGDisplayModelNumber(displayID)
        product.serialNumber = CGDisplaySerialNumber(displayID)

        return DisplayIdentity(
            displayID: displayID,
            registryID: registryID,
            product: product
        )
    }

    private func registryCandidates() throws -> [RegistryCandidate] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else {
            throw DDCTransportError.registryTraversalFailed(kIOReturnNotFound)
        }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        let result = IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard result == kIOReturnSuccess else {
            if iterator != IO_OBJECT_NULL { IOObjectRelease(iterator) }
            throw DDCTransportError.registryTraversalFailed(result)
        }
        defer { IOObjectRelease(iterator) }

        var currentFramebuffer: FramebufferSnapshot?
        var candidates: [RegistryCandidate] = []

        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            let name = registryEntryName(entry)
            let isFramebuffer = IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0
                || name.contains("IOMobileFramebufferShim")
                || name.contains("AppleCLCD2")

            if isFramebuffer {
                currentFramebuffer = FramebufferSnapshot(
                    registryID: registryEntryID(entry),
                    product: productIdentity(from: entry)
                )
                continue
            }

            guard name == "DCPAVServiceProxy",
                  registryString("Location", from: entry, recursive: true) == "External",
                  let framebuffer = currentFramebuffer,
                  let service = try coreDisplay.createService(for: entry) else {
                continue
            }

            let route = isMCDP29xxProxy(entry) ? DDCTransportRoute.mcdp29xx : .standard
            candidates.append(
                RegistryCandidate(
                    service: service,
                    chipAddress: route == .mcdp29xx
                        ? DDCPacketCodec.mcdp29xxChipAddress
                        : DDCPacketCodec.standardChipAddress,
                    route: route,
                    framebuffer: framebuffer
                )
            )
        }

        return candidates
    }

    func isMCDP29xxProxy(_ proxy: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == kIOReturnSuccess else {
            return false
        }
        defer { IOObjectRelease(parent) }
        return registryString("EPICProviderClass", from: parent) == "AppleDCPMCDP29XX"
    }

    private func matchScore(_ display: DisplayIdentity, _ framebuffer: FramebufferSnapshot) -> Int {
        if let displayRegistryID = display.registryID,
           let framebufferRegistryID = framebuffer.registryID,
           displayRegistryID == framebufferRegistryID {
            return 1_000
        }

        var score = 0
        let lhs = display.product
        let rhs = framebuffer.product

        if lhs.vendorID != 0, lhs.vendorID == rhs.vendorID { score += 8 }
        if lhs.productID != 0, lhs.productID == rhs.productID { score += 8 }
        if lhs.serialNumber != 0, lhs.serialNumber == rhs.serialNumber { score += 6 }
        if !lhs.alphanumericSerialNumber.isEmpty,
           normalized(lhs.alphanumericSerialNumber) == normalized(rhs.alphanumericSerialNumber) {
            score += 5
        }
        if !lhs.name.isEmpty, normalized(lhs.name) == normalized(rhs.name) { score += 3 }
        if !lhs.manufacturerID.isEmpty,
           normalized(lhs.manufacturerID) == normalized(rhs.manufacturerID) {
            score += 2
        }
        return score
    }

    private func productIdentity(from entry: io_registry_entry_t) -> ProductIdentity {
        guard let displayAttributes = registryDictionary("DisplayAttributes", from: entry, recursive: true),
              let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any] else {
            return ProductIdentity()
        }

        return ProductIdentity(
            vendorID: unsignedValue(productAttributes["LegacyManufacturerID"]),
            productID: unsignedValue(productAttributes["ProductID"]),
            serialNumber: unsignedValue(productAttributes["SerialNumber"]),
            manufacturerID: productAttributes["ManufacturerID"] as? String ?? "",
            alphanumericSerialNumber: productAttributes["AlphanumericSerialNumber"] as? String ?? "",
            name: productAttributes["ProductName"] as? String ?? ""
        )
    }

    func registryDictionary(
        _ key: String,
        from entry: io_registry_entry_t,
        recursive: Bool = false
    ) -> [String: Any]? {
        registryProperty(key, from: entry, recursive: recursive) as? [String: Any]
    }

    func registryString(
        _ key: String,
        from entry: io_registry_entry_t,
        recursive: Bool = false
    ) -> String? {
        registryProperty(key, from: entry, recursive: recursive) as? String
    }

    func registryProperty(
        _ key: String,
        from entry: io_registry_entry_t,
        recursive: Bool
    ) -> Any? {
        let options = recursive ? IOOptionBits(kIORegistryIterateRecursively) : 0
        guard let property = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            options
        ) else {
            return nil
        }
        return property
    }

    func registryEntryID(_ entry: io_registry_entry_t) -> UInt64? {
        var registryID: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &registryID) == kIOReturnSuccess
            ? registryID
            : nil
    }

    func registryEntryName(_ entry: io_registry_entry_t) -> String {
        // IOKit declares io_name_t as a 128-byte C buffer.
        var buffer = [CChar](repeating: 0, count: 128)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            IORegistryEntryGetName(entry, pointer.baseAddress)
        }
        return result == kIOReturnSuccess ? String(cString: buffer) : ""
    }

    func unsignedValue(_ value: Any?) -> UInt32 {
        if let number = value as? NSNumber { return number.uint32Value }
        if let value = value as? UInt32 { return value }
        if let value = value as? Int { return UInt32(clamping: value) }
        return 0
    }

    func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func sleep(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}
