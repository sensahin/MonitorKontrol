//
//  DDCPacketTests.swift
//  MonitorKontrolTests
//

import Testing
@testable import MonitorKontrol

struct DDCPacketTests {
    @Test func checksumUsesXORSeed() {
        let checksum = DDCPacketCodec.checksum(
            seed: 0x6E,
            bytes: [0x82, 0x01, 0x10]
        )

        #expect(checksum == 0xFD)
    }

    @Test func brightnessReadPacketMatchesDDCCIFraming() {
        #expect(DDCPacketCodec.readRequest(for: .brightness) == [0x82, 0x01, 0x10, 0xFD])
    }

    @Test func brightnessWritePacketIncludesDataAddressInChecksum() {
        #expect(
            DDCPacketCodec.writeRequest(for: .brightness, value: 100)
                == [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC]
        )
    }

    @Test func parsesValidatedVCPReply() throws {
        var reply: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, 0x10, 0x00,
            0x00, 0x64, 0x00, 0x32
        ]
        reply.append(
            DDCPacketCodec.checksum(seed: DDCPacketCodec.hostReplyAddress, bytes: reply)
        )
        reply.append(0x00) // IOAVService reads into a 12-byte buffer.

        let value = try DDCPacketCodec.parseVCPReply(reply, expecting: .brightness)

        #expect(value.code == .brightness)
        #expect(value.current == 50)
        #expect(value.maximum == 100)
        #expect(value.normalized == 0.5)
        #expect(value.isMomentary == false)
    }

    @Test func rejectsChecksumMismatch() {
        let reply: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, 0x10, 0x00,
            0x00, 0x64, 0x00, 0x32, 0x00
        ]

        #expect(throws: DDCTransportError.self) {
            try DDCPacketCodec.parseVCPReply(reply, expecting: .brightness)
        }
    }

    @Test func unsupportedFeatureReplyIsReportedWithoutMutation() {
        var reply: [UInt8] = [
            0x6E, 0x88, 0x02, 0x01, 0x62, 0x00,
            0x00, 0x00, 0x00, 0x00
        ]
        reply.append(
            DDCPacketCodec.checksum(seed: DDCPacketCodec.hostReplyAddress, bytes: reply)
        )

        #expect(throws: DDCTransportError.unsupportedVCPCode(0x62)) {
            try DDCPacketCodec.parseVCPReply(reply, expecting: .speakerVolume)
        }
    }

    @Test func staleEndpointIsRejectedBeforeHardwareIO() async {
        let transport = DDCTransport()
        let endpoint = DDCDisplayEndpoint(
            displayID: 99,
            route: .standard,
            generation: 1
        )

        await #expect(throws: DDCTransportError.staleEndpoint(99)) {
            try await transport.read(.brightness, from: endpoint)
        }
    }

    @Test func cancellationBarrierInvalidatesIssuedEndpointBeforeHardwareIO() async {
        let transport = DDCTransport()
        let endpoint = DDCDisplayEndpoint(
            displayID: 99,
            route: .standard,
            generation: 0
        )

        transport.cancelPendingWrites()

        await #expect(throws: DDCTransportError.staleEndpoint(99)) {
            try await transport.write(
                .brightness,
                value: 50,
                to: endpoint,
                coalescing: false
            )
        }
    }
}
