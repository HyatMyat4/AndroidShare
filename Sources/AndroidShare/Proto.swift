import Foundation

/// Minimal protobuf encoder/decoder: just enough for the Quick Share wire format,
/// so the project doesn't need SwiftProtobuf or generated code.
struct ProtoWriter {
    private(set) var data = Data()

    static func build(_ body: (inout ProtoWriter) -> Void) -> Data {
        var w = ProtoWriter()
        body(&w)
        return w.data
    }

    private mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wire: UInt64) { varint(UInt64(field) << 3 | wire) }

    mutating func int(_ field: Int, _ value: Int64) { tag(field, 0); varint(UInt64(bitPattern: value)) }
    mutating func int(_ field: Int, _ value: Int) { int(field, Int64(value)) }
    mutating func bool(_ field: Int, _ value: Bool) { int(field, value ? 1 : 0) }
    mutating func bytes(_ field: Int, _ value: Data) { tag(field, 2); varint(UInt64(value.count)); data.append(value) }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ body: (inout ProtoWriter) -> Void) { bytes(field, ProtoWriter.build(body)) }
}

struct ProtoMessage {
    enum Value { case varint(UInt64), bytes(Data), fixed64(UInt64), fixed32(UInt32) }
    struct DecodeError: Error {}

    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let b = [UInt8](data)
        var i = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw DecodeError() }
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        while i < b.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                value = .varint(try readVarint())
            case 1:
                guard i + 8 <= b.count else { throw DecodeError() }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8
                value = .fixed64(v)
            case 2:
                let len = Int(try readVarint())
                guard len >= 0, i + len <= b.count else { throw DecodeError() }
                value = .bytes(Data(b[i..<(i + len)]))
                i += len
            case 5:
                guard i + 4 <= b.count else { throw DecodeError() }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
                i += 4
                value = .fixed32(v)
            default:
                throw DecodeError()
            }
            fields[field, default: []].append(value)
        }
    }

    func int(_ field: Int) -> Int64? {
        guard case .varint(let v)? = fields[field]?.last else { return nil }
        return Int64(bitPattern: v)
    }

    func bool(_ field: Int) -> Bool { (int(field) ?? 0) != 0 }

    func bytes(_ field: Int) -> Data? {
        guard case .bytes(let d)? = fields[field]?.last else { return nil }
        return d
    }

    func string(_ field: Int) -> String? { bytes(field).map { String(decoding: $0, as: UTF8.self) } }

    func message(_ field: Int) -> ProtoMessage? { bytes(field).flatMap { try? ProtoMessage($0) } }

    func messages(_ field: Int) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap {
            if case .bytes(let d) = $0 { return try? ProtoMessage(d) }
            return nil
        }
    }
}
