import Foundation

public enum ContinuityError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Bounded protobuf wire handling for the observed MCF envelope. No generated
/// Samsung code is included. Unknown fields are retained by the field reader.
public enum ProtoWire {
    public enum Value: Equatable { case number(UInt64), bytes(Data) }
    public static let maximumFrame = 8 * 1024 * 1024
    public static func varint(_ input: UInt64) -> Data {
        var value = input; var result = Data()
        while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }
        result.append(UInt8(value)); return result
    }
    public static func readVarint(_ data: Data, cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard cursor < data.count else { throw ContinuityError.message("Truncated protobuf integer.") }
            let byte = data[data.startIndex + cursor]; cursor += 1
            guard index != 9 || byte <= 1 else { throw ContinuityError.message("Protobuf integer overflow.") }
            result |= UInt64(byte & 127) << (index * 7)
            if byte & 128 == 0 { return result }
        }
        throw ContinuityError.message("Invalid protobuf integer.")
    }
    public static func number(_ tag: Int, _ value: UInt64) -> Data { varint(UInt64(tag << 3)) + varint(value) }
    public static func bytes(_ tag: Int, _ value: Data) -> Data { varint(UInt64(tag << 3 | 2)) + varint(UInt64(value.count)) + value }
    public static func fields(_ data: Data) throws -> [Int: [Value]] {
        guard data.count <= maximumFrame else { throw ContinuityError.message("Protobuf frame is too large.") }
        var cursor = 0; var fields: [Int: [Value]] = [:]
        while cursor < data.count {
            let key = try readVarint(data, cursor: &cursor), tag = Int(key >> 3), wire = key & 7
            guard tag > 0, tag <= 536870911 else { throw ContinuityError.message("Invalid protobuf tag.") }
            if wire == 0 { fields[tag, default: []].append(.number(try readVarint(data, cursor: &cursor))); continue }
            let length: Int
            switch wire {
            case 1: length = 8
            case 5: length = 4
            case 2:
                let count = try readVarint(data, cursor: &cursor)
                guard count <= maximumFrame else { throw ContinuityError.message("Invalid protobuf byte length.") }
                length = Int(count)
            default: throw ContinuityError.message("Unsupported protobuf wire type.")
            }
            guard length <= data.count - cursor else { throw ContinuityError.message("Truncated protobuf bytes.") }
            let begin = data.startIndex + cursor
            fields[tag, default: []].append(.bytes(data.subdata(in: begin..<(begin + length)))); cursor += length
        }
        return fields
    }
    public static func number(_ fields: [Int: [Value]], _ tag: Int) -> UInt64 { if case .number(let n) = fields[tag]?.last { return n }; return 0 }
    public static func bytes(_ fields: [Int: [Value]], _ tag: Int) -> Data { if case .bytes(let d) = fields[tag]?.last { return d }; return Data() }
}

public struct MCFPacket {
    public var handler: UInt64 = 0
    public var sequence: UInt64 = 0
    public var payload = Data()
    public var advPayload = Data()
    public var accountRevision: UInt64 = 0
    public var authType: UInt64 = 0
    public var iv = Data()
    public init(handler: UInt64 = 0, sequence: UInt64 = 0, payload: Data, advPayload: Data = Data(), accountRevision: UInt64 = 0, authType: UInt64 = 0, iv: Data = Data()) {
        self.handler = handler; self.sequence = sequence; self.payload = payload; self.accountRevision = accountRevision; self.authType = authType; self.iv = iv
        self.advPayload = advPayload
    }
    public init(data: Data) throws {
        let f = try ProtoWire.fields(data)
        handler = ProtoWire.number(f, 1); sequence = ProtoWire.number(f, 2); payload = ProtoWire.bytes(f, 3)
        advPayload = ProtoWire.bytes(f, 4)
        accountRevision = ProtoWire.number(f, 5); authType = ProtoWire.number(f, 6); iv = ProtoWire.bytes(f, 7)
    }
    public var encoded: Data {
        var d = ProtoWire.number(1, handler) + ProtoWire.number(2, sequence) + ProtoWire.bytes(3, payload)
        if !advPayload.isEmpty { d += ProtoWire.bytes(4, advPayload) }
        if accountRevision != 0 { d += ProtoWire.number(5, accountRevision) }
        if authType != 0 { d += ProtoWire.number(6, authType) }
        if !iv.isEmpty { d += ProtoWire.bytes(7, iv) }
        return d
    }
    public var framed: Data { ProtoWire.varint(UInt64(encoded.count)) + encoded }
}

public struct MCFCommand {
    public var id: UInt64; public var type: UInt64; public var payload: Data
    public init(id: UInt64, type: UInt64, payload: Data = Data()) { self.id = id; self.type = type; self.payload = payload }
    public init(data: Data) throws { let f = try ProtoWire.fields(data); id = ProtoWire.number(f, 1); type = ProtoWire.number(f, 2); payload = ProtoWire.bytes(f, 3) }
    public var encoded: Data { ProtoWire.number(1, id) + ProtoWire.number(2, type) + ProtoWire.bytes(3, payload) }
}

public struct ClipboardText: Codable, Equatable {
    public var id: String; public var timestamp: String; public var type: String = "TEXT"
    public var source: String; public var text: String
    public var html: String?
    public var files: [ClipboardFile]?
    public init(text: String, source: String, milliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = String(milliseconds); self.timestamp = self.id; self.source = source; self.text = text
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    enum CodingKeys: String, CodingKey { case id, timestamp, type, source, text, html, files }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id); timestamp = try fields.decodeIfPresent(String.self, forKey: .timestamp) ?? id
        type = try fields.decode(String.self, forKey: .type); source = try fields.decode(String.self, forKey: .source)
        text = try fields.decodeIfPresent(String.self, forKey: .text) ?? ""
        html = try fields.decodeIfPresent(String.self, forKey: .html); files = try fields.decodeIfPresent([ClipboardFile].self, forKey: .files)
    }
}

public struct ClipboardFile: Codable, Equatable {
    public var originalUri: String
    public var fileName: String
    public var fileLength: Int
    public var needUriList: Bool = false
    public init(uri: String, name: String, size: Int) { originalUri = uri; fileName = name; fileLength = size }
}

public struct ClipboardLoopGuard {
    private var remoteID: String?
    private var remoteText: String?
    public init() {}
    public mutating func received(_ clip: ClipboardText) -> Bool {
        guard clip.id != remoteID else { return false }
        remoteID = clip.id; remoteText = clip.text; return true
    }
    public mutating func shouldPublish(_ text: String) -> Bool {
        if text == remoteText { remoteText = nil; return false }
        remoteText = nil; return true
    }
}
