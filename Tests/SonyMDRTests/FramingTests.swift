import Testing
@testable import SonyMDR

// Byte-exact vectors. These double as the spec for ports to other languages.

@Suite struct FramingTests {
    @Test func encodesGetProtocolInfo() {
        // 3E | 0C 00 00000002 00 00 | sum=0x0E | 3C
        let bytes = MDRFraming.encode(MDRFrame(.dataMDR, sequence: 0, payload: [0x00, 0x00]))
        #expect(bytes == [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C])
    }

    @Test func ackFramesMatchTheApp() {
        // qm0.b: precomputed ACKs for received seq 1 and 0
        #expect(MDRFraming.ack(forReceivedSequence: 1) == [0x3E, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x3C])
        #expect(MDRFraming.ack(forReceivedSequence: 0) == [0x3E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3C])
    }

    @Test func escapesReservedBytes() throws {
        #expect(MDRFraming.escape([0x3C, 0x3D, 0x3E, 0x41]) == [0x3D, 0x2C, 0x3D, 0x2D, 0x3D, 0x2E, 0x41])
        #expect(try MDRFraming.unescape([0x3D, 0x2C, 0x3D, 0x2D, 0x3D, 0x2E, 0x41]) == [0x3C, 0x3D, 0x3E, 0x41])
    }

    @Test func checksumIsWrappingSum() {
        #expect(MDRFraming.checksum([0xFF, 0x02]) == 0x01)
    }

    @Test func roundTripsWithEscapingInPayloadAndChecksum() throws {
        let frame = MDRFrame(.dataMDR, sequence: 1, payload: [0x3E, 0x3C, 0x3D, 0x00, 0xFF])
        var dec = MDRFrameDecoder()
        let out = dec.feed(MDRFraming.encode(frame))
        #expect(out.count == 1)
        #expect(try out[0].get() == frame)
    }

    @Test func decoderHandlesSplitChunksAndGarbage() throws {
        let a = MDRFraming.encode(MDRFrame(.dataMDR, sequence: 0, payload: [0x11, 0x00, 0x46, 0x00]))
        let b = MDRFraming.encode(MDRFrame(.ack, sequence: 1, payload: []))
        let stream = [0x00, 0x99] + a + b
        var dec = MDRFrameDecoder()
        var frames: [MDRFrame] = []
        for chunk in stride(from: 0, to: stream.count, by: 3).map({ Array(stream[$0 ..< min($0 + 3, stream.count)]) }) {
            frames += dec.feed(chunk).compactMap { try? $0.get() }
        }
        #expect(frames.map(\.payload) == [[0x11, 0x00, 0x46, 0x00], []])
    }

    @Test func rejectsBadChecksum() {
        var bytes = MDRFraming.encode(MDRFrame(.dataMDR, sequence: 0, payload: [0x10, 0x00]))
        bytes[bytes.count - 2] &+= 1
        var dec = MDRFrameDecoder()
        #expect(dec.feed(bytes) == [.failure(.badChecksum)])
    }
}
