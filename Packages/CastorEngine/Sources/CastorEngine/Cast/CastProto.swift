import Foundation

/// The single protobuf message type of the CASTv2 protocol, framed with a
/// 4-byte big-endian length prefix. Hand-rolled — pulling in a protobuf
/// dependency for one seven-field message isn't worth it.
///
///     message CastMessage {
///       required ProtocolVersion protocol_version = 1;  // varint, always 0
///       required string source_id = 2;
///       required string destination_id = 3;
///       required string namespace = 4;
///       required PayloadType payload_type = 5;          // 0 = STRING, 1 = BINARY
///       optional string payload_utf8 = 6;
///       optional bytes payload_binary = 7;
///     }
struct CastMessage: Equatable, Sendable {
    var sourceId: String
    var destinationId: String
    var namespace: String
    var payload: String

    enum ProtoError: Error {
        case truncated
        case malformed
    }

    // MARK: - Encoding

    func encodedFrame() -> Data {
        var body = Data()
        Self.appendVarintField(1, value: 0, to: &body) // CASTV2_1_0
        Self.appendStringField(2, value: sourceId, to: &body)
        Self.appendStringField(3, value: destinationId, to: &body)
        Self.appendStringField(4, value: namespace, to: &body)
        Self.appendVarintField(5, value: 0, to: &body) // STRING payload
        Self.appendStringField(6, value: payload, to: &body)

        var frame = Data(capacity: body.count + 4)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }

    private static func appendVarintField(_ field: UInt64, value: UInt64, to data: inout Data) {
        appendVarint(field << 3 | 0, to: &data)
        appendVarint(value, to: &data)
    }

    private static func appendStringField(_ field: UInt64, value: String, to data: inout Data) {
        appendVarint(field << 3 | 2, to: &data)
        let bytes = Data(value.utf8)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    // MARK: - Decoding

    /// Decodes a message body (without the length prefix).
    static func decode(body: Data) throws -> CastMessage {
        var fields: [UInt64: Data] = [:]
        var varints: [UInt64: UInt64] = [:]
        var index = body.startIndex

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < body.endIndex, shift < 64 else { throw ProtoError.truncated }
                let byte = body[index]
                index = body.index(after: index)
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        while index < body.endIndex {
            let tag = try readVarint()
            let field = tag >> 3
            switch tag & 0x7 {
            case 0:
                varints[field] = try readVarint()
            case 2:
                let length = try readVarint()
                guard let end = body.index(index, offsetBy: Int(length), limitedBy: body.endIndex) else {
                    throw ProtoError.truncated
                }
                fields[field] = body.subdata(in: index..<end)
                index = end
            default:
                throw ProtoError.malformed
            }
        }

        func string(_ field: UInt64) -> String? {
            fields[field].flatMap { String(data: $0, encoding: .utf8) }
        }

        guard let source = string(2), let destination = string(3), let namespace = string(4) else {
            throw ProtoError.malformed
        }
        return CastMessage(
            sourceId: source,
            destinationId: destination,
            namespace: namespace,
            payload: string(6) ?? ""
        )
    }
}
