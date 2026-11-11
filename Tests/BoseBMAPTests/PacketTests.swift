import Testing
@testable import BoseBMAP

// Byte-exact vectors for the BMAP packet layer (BmapPacket.toByteArray / createFromByteArray).

@Suite struct PacketTests {
    @Test func encodesHeader() {
        // ProductInfo(0).FirmwareVersion(5) Get, no payload
        #expect(BMAPPacket(0, 5, .get).encoded() == [0x00, 0x05, 0x01, 0x00])
        // device ID and port live in the top bits of the operator byte
        #expect(BMAPPacket(1, 2, .setGet, [0x01], deviceID: 1, port: 2).encoded() == [0x01, 0x02, 0x62, 0x01, 0x01])
    }

    @Test func decodesSeveralPacketsInOneRead() {
        var dec = BMAPPacketDecoder()
        let packets = dec.feed([0x02, 0x02, 0x03, 0x01, 0x50, 0x00, 0x05, 0x03, 0x02, 0x31, 0x2E])
        #expect(packets == [BMAPPacket(2, 2, .status, [0x50]), BMAPPacket(0, 5, .status, [0x31, 0x2E])])
    }

    @Test func keepsPartialPacketsAcrossReads() {
        var dec = BMAPPacketDecoder()
        #expect(dec.feed([0x02, 0x02]).isEmpty)
        #expect(dec.feed([0x03, 0x02, 0x50]).isEmpty)
        #expect(dec.feed([0x00, 0x01, 0x05]) == [BMAPPacket(2, 2, .status, [0x50, 0x00])])
        #expect(dec.feed([0x01, 0x00]) == [BMAPPacket(1, 5, .get)])
    }

    @Test func decodesDeviceIDAndPort() {
        var dec = BMAPPacketDecoder()
        let p = dec.feed([0x01, 0x02, 0x63, 0x00]).first
        #expect(p?.deviceID == 1)
        #expect(p?.port == 2)
        #expect(p?.op == .status)
    }
}
