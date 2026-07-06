import Foundation
import Testing
@testable import CastorEngine

@Suite struct CastProtoTests {
    @Test func roundTrip() throws {
        let message = CastMessage(
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.tp.connection",
            payload: #"{"type":"CONNECT"}"#
        )
        let frame = message.encodedFrame()

        // 4-byte big-endian length prefix.
        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        #expect(Int(length) == frame.count - 4)

        let decoded = try CastMessage.decode(body: frame.dropFirst(4))
        #expect(decoded == message)
    }

    @Test func decodesKnownGoodFrame() throws {
        // CONNECT message captured from the encoder, verified byte-by-byte
        // against the CASTv2 wire format: field 1 varint 0, fields 2/3/4/6
        // length-delimited strings, field 5 varint 0.
        let hex = "0800120873656e6465722d301a0a72656365697665722d3022287572" +
                  "6e3a782d636173743a636f6d2e676f6f676c652e636173742e74702e" +
                  "636f6e6e656374696f6e280032127b2274797065223a22434f4e4e45" +
                  "4354227d"
        var body = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            body.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }

        let decoded = try CastMessage.decode(body: body)
        #expect(decoded.sourceId == "sender-0")
        #expect(decoded.destinationId == "receiver-0")
        #expect(decoded.namespace == "urn:x-cast:com.google.cast.tp.connection")
        #expect(decoded.payload == #"{"type":"CONNECT"}"#)
    }

    @Test func multiByteVarintLengths() throws {
        // Payloads longer than 127 bytes exercise multi-byte varint lengths.
        let long = CastMessage(
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.media",
            payload: #"{"type":"LOAD","media":{"contentId":"\#(String(repeating: "x", count: 500))"}}"#
        )
        let decoded = try CastMessage.decode(body: long.encodedFrame().dropFirst(4))
        #expect(decoded == long)
    }

    @Test func truncatedFrameThrows() {
        let frame = CastMessage(
            sourceId: "s", destinationId: "d", namespace: "n", payload: "p"
        ).encodedFrame()
        // Dropping one byte truncates the final length-delimited field
        // mid-value; dropping more would remove whole fields cleanly.
        #expect(throws: CastMessage.ProtoError.self) {
            try CastMessage.decode(body: frame.dropFirst(4).dropLast(1))
        }
    }
}
