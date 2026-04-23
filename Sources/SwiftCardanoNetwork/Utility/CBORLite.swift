import NIOCore

/// Minimal CBOR encode/decode utilities for the Ouroboros protocol messages.
///
/// This is **not** a complete CBOR implementation. It covers only the subset of
/// CBOR used by Cardano's NtC/NtN protocol message payloads. Replace with
/// `swift-cardano-core` when that package is integrated.
///
/// All functions are `internal` — they are shared across codec implementations
/// within `CardanoNetwork` but are not part of the public API.
enum CBORLite {

    // MARK: - CBOR major types

    static let majorUInt: UInt8 = 0
    static let majorNInt: UInt8 = 1
    static let majorByteString: UInt8 = 2
    static let majorTextString: UInt8 = 3
    static let majorArray: UInt8 = 4
    static let majorMap: UInt8 = 5
    static let majorTag: UInt8 = 6
    static let majorSimple: UInt8 = 7

    // MARK: - Write helpers

    static func writeUInt(_ v: UInt64, into buf: inout ByteBuffer) {
        writeHead(major: majorUInt, info: v, into: &buf)
    }

    static func writeNInt(_ v: UInt64, into buf: inout ByteBuffer) {
        writeHead(major: majorNInt, info: v, into: &buf)
    }

    static func writeByteString(_ bytes: [UInt8], into buf: inout ByteBuffer) {
        writeHead(major: majorByteString, info: UInt64(bytes.count), into: &buf)
        buf.writeBytes(bytes)
    }

    static func writeByteBuffer(_ source: ByteBuffer, into buf: inout ByteBuffer) {
        var src = source
        writeHead(major: majorByteString, info: UInt64(src.readableBytes), into: &buf)
        buf.writeBuffer(&src)
    }

    static func writeText(_ s: String, into buf: inout ByteBuffer) {
        let bytes = Array(s.utf8)
        writeHead(major: majorTextString, info: UInt64(bytes.count), into: &buf)
        buf.writeBytes(bytes)
    }

    static func writeArrayHeader(count: Int, into buf: inout ByteBuffer) {
        writeHead(major: majorArray, info: UInt64(count), into: &buf)
    }

    static func writeMapHeader(count: Int, into buf: inout ByteBuffer) {
        writeHead(major: majorMap, info: UInt64(count), into: &buf)
    }

    static func writeTag(_ tag: UInt64, into buf: inout ByteBuffer) {
        writeHead(major: majorTag, info: tag, into: &buf)
    }

    static func writeBool(_ v: Bool, into buf: inout ByteBuffer) {
        buf.writeInteger(v ? UInt8(0xF5) : UInt8(0xF4))
    }

    static func writeNull(into buf: inout ByteBuffer) {
        buf.writeInteger(UInt8(0xF6))
    }

    // MARK: - Read helpers

    /// Peek at the major type of the next value without consuming any bytes.
    static func peekMajorType(from buf: ByteBuffer) -> UInt8? {
        buf.getInteger(at: buf.readerIndex, as: UInt8.self).map { $0 >> 5 }
    }

    /// Return `true` if the next byte is the CBOR null simple value (0xF6) without consuming it.
    static func peekIsNull(_ buf: ByteBuffer) -> Bool {
        buf.getInteger(at: buf.readerIndex, as: UInt8.self) == 0xF6
    }

    /// Return `true` if the next byte is the CBOR break code (0xFF) without consuming it.
    static func peekIsBreak(_ buf: ByteBuffer) -> Bool {
        buf.getInteger(at: buf.readerIndex, as: UInt8.self) == 0xFF
    }

    /// Consume the CBOR break byte (0xFF) if it is the next byte in the buffer.
    static func skipBreakIfPresent(from buf: inout ByteBuffer) {
        if buf.getInteger(at: buf.readerIndex, as: UInt8.self) == 0xFF {
            buf.moveReaderIndex(forwardBy: 1)
        }
    }

    /// Consume the CBOR null simple value (0xF6).
    static func readNull(from buf: inout ByteBuffer) throws {
        let b = try readByte(from: &buf)
        guard b == 0xF6 else { throw CBORError.typeMismatch(expected: "null", got: b) }
    }

    /// Read and return an unsigned integer (major type 0).
    static func readUInt(from buf: inout ByteBuffer) throws -> UInt64 {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorUInt else {
            throw CBORError.typeMismatch(expected: "uint", got: initial)
        }
        return try readAdditionalInfo(initial & 0x1F, from: &buf)
    }

    /// Read and return a byte string (major type 2) as `[UInt8]`.
    static func readByteString(from buf: inout ByteBuffer) throws -> [UInt8] {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorByteString else {
            throw CBORError.typeMismatch(expected: "bytes", got: initial)
        }
        let length = Int(try readAdditionalInfo(initial & 0x1F, from: &buf))
        guard let bytes = buf.readBytes(length: length) else { throw CBORError.truncated }
        return bytes
    }

    /// Read and return a byte string (major type 2) as a `ByteBuffer` slice.
    /// Supports both definite-length and indefinite-length (chunked) encoding.
    static func readByteStringBuffer(from buf: inout ByteBuffer) throws -> ByteBuffer {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorByteString else {
            throw CBORError.typeMismatch(expected: "bytes", got: initial)
        }
        let info = initial & 0x1F
        if info == 31 {
            // Indefinite-length: collect definite chunks until break (0xFF).
            var result = ByteBuffer()
            while true {
                guard let next = buf.readInteger(as: UInt8.self) else { throw CBORError.truncated }
                if next == 0xFF { break }
                guard (next >> 5) == majorByteString else {
                    throw CBORError.typeMismatch(expected: "bytes chunk", got: next)
                }
                let chunkLen = Int(try readAdditionalInfo(next & 0x1F, from: &buf))
                guard var chunk = buf.readSlice(length: chunkLen) else { throw CBORError.truncated }
                result.writeBuffer(&chunk)
            }
            return result
        }
        let length = Int(try readAdditionalInfo(info, from: &buf))
        guard let slice = buf.readSlice(length: length) else { throw CBORError.truncated }
        return slice
    }

    /// Read and return a text string (major type 3).
    static func readText(from buf: inout ByteBuffer) throws -> String {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorTextString else {
            throw CBORError.typeMismatch(expected: "text", got: initial)
        }
        let length = Int(try readAdditionalInfo(initial & 0x1F, from: &buf))
        guard let bytes = buf.readBytes(length: length) else { throw CBORError.truncated }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Read an array header (major type 4); returns the element count, or -1 for indefinite-length.
    static func readArrayHeader(from buf: inout ByteBuffer) throws -> Int {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorArray else {
            throw CBORError.typeMismatch(expected: "array", got: initial)
        }
        let info = initial & 0x1F
        if info == 31 { return -1 }  // indefinite-length
        return Int(try readAdditionalInfo(info, from: &buf))
    }

    /// Read a map header (major type 5); returns the pair count, or -1 for indefinite-length.
    static func readMapHeader(from buf: inout ByteBuffer) throws -> Int {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorMap else {
            throw CBORError.typeMismatch(expected: "map", got: initial)
        }
        let info = initial & 0x1F
        if info == 31 { return -1 }  // indefinite-length
        return Int(try readAdditionalInfo(info, from: &buf))
    }

    /// Read a CBOR tag (major type 6); returns the tag number.
    static func readTag(from buf: inout ByteBuffer) throws -> UInt64 {
        let initial = try readByte(from: &buf)
        guard (initial >> 5) == majorTag else {
            throw CBORError.typeMismatch(expected: "tag", got: initial)
        }
        return try readAdditionalInfo(initial & 0x1F, from: &buf)
    }

    /// Read a signed integer (major type 0 = uint, or major type 1 = nint).
    static func readInt64(from buf: inout ByteBuffer) throws -> Int64 {
        let initial = try readByte(from: &buf)
        let major = initial >> 5
        let n = try readAdditionalInfo(initial & 0x1F, from: &buf)
        switch major {
        case majorUInt: return Int64(bitPattern: n)
        case majorNInt: return -1 - Int64(bitPattern: n)
        default: throw CBORError.typeMismatch(expected: "integer", got: initial)
        }
    }

    /// Read a boolean simple value (0xF4 = false, 0xF5 = true).
    static func readBool(from buf: inout ByteBuffer) throws -> Bool {
        let b = try readByte(from: &buf)
        switch b {
        case 0xF4: return false
        case 0xF5: return true
        default: throw CBORError.typeMismatch(expected: "bool", got: b)
        }
    }

    // MARK: - Capture a complete CBOR value as a buffer slice

    /// Read exactly one complete CBOR value (of any type, including nested
    /// arrays/maps) and return it as a `ByteBuffer` slice.
    ///
    /// Uses a probe copy to measure the value's byte length without consuming
    /// the original buffer prematurely, then advances the reader by that length.
    ///
    /// Used by `RawResult.decodeUTxOs()` to extract individual map keys and
    /// values before passing them to SwiftCardanoCore's `fromCBOR(data:)`.
    static func readValueBuffer(from buf: inout ByteBuffer) throws -> ByteBuffer {
        var probe = buf
        try skipValue(in: &probe)
        let length = probe.readerIndex - buf.readerIndex
        guard let slice = buf.readSlice(length: length) else {
            throw CBORError.truncated
        }
        return slice
    }

    // MARK: - Skip a complete CBOR value

    /// Advance `buf.readerIndex` past exactly one CBOR value (any type, including
    /// arrays/maps recursively). Supports indefinite-length encoding (info == 31).
    static func skipValue(in buf: inout ByteBuffer) throws {
        let initial = try readByte(from: &buf)
        let major = initial >> 5
        let info = initial & 0x1F

        // Indefinite-length encoding (info == 31) — handle per major type.
        if info == 31 {
            switch major {
            case majorByteString, majorTextString:
                // Chunked: read definite-length chunks until break (0xFF).
                while true {
                    guard let next = buf.readInteger(as: UInt8.self) else {
                        throw CBORError.truncated
                    }
                    if next == 0xFF { return }
                    let chunkLen = Int(try readAdditionalInfo(next & 0x1F, from: &buf))
                    guard buf.readableBytes >= chunkLen else { throw CBORError.truncated }
                    buf.moveReaderIndex(forwardBy: chunkLen)
                }
            case majorArray:
                while true {
                    guard let peek = buf.getInteger(at: buf.readerIndex, as: UInt8.self) else {
                        throw CBORError.truncated
                    }
                    if peek == 0xFF {
                        buf.moveReaderIndex(forwardBy: 1)
                        return
                    }
                    try skipValue(in: &buf)
                }
            case majorMap:
                while true {
                    guard let peek = buf.getInteger(at: buf.readerIndex, as: UInt8.self) else {
                        throw CBORError.truncated
                    }
                    if peek == 0xFF {
                        buf.moveReaderIndex(forwardBy: 1)
                        return
                    }
                    try skipValue(in: &buf)  // key
                    try skipValue(in: &buf)  // value
                }
            case majorSimple:
                // 0xFF is the break code — treated as consumed by the initial readByte.
                return
            default:
                throw CBORError.unsupportedMajorType(major)
            }
            return
        }

        let count = Int(try readAdditionalInfo(info, from: &buf))

        switch major {
        case majorUInt, majorNInt:
            break  // already consumed by readAdditionalInfo

        case majorByteString, majorTextString:
            guard buf.readableBytes >= count else { throw CBORError.truncated }
            buf.moveReaderIndex(forwardBy: count)

        case majorArray:
            for _ in 0..<count { try skipValue(in: &buf) }

        case majorMap:
            for _ in 0..<count {
                try skipValue(in: &buf)  // key
                try skipValue(in: &buf)  // value
            }

        case majorTag:
            try skipValue(in: &buf)  // tagged value

        case majorSimple:
            // float 16: 2 extra bytes, float 32: 4 extra, float 64: 8 extra
            switch info {
            case 25: buf.moveReaderIndex(forwardBy: 2)
            case 26: buf.moveReaderIndex(forwardBy: 4)
            case 27: buf.moveReaderIndex(forwardBy: 8)
            default: break
            }

        default:
            throw CBORError.unsupportedMajorType(major)
        }
    }

    // MARK: - Private internals

    private static func readByte(from buf: inout ByteBuffer) throws -> UInt8 {
        guard let b = buf.readInteger(as: UInt8.self) else { throw CBORError.truncated }
        return b
    }

    private static func readAdditionalInfo(_ info: UInt8, from buf: inout ByteBuffer) throws
        -> UInt64
    {
        switch info {
        case 0...23: return UInt64(info)
        case 24:
            guard let v = buf.readInteger(as: UInt8.self) else { throw CBORError.truncated }
            return UInt64(v)
        case 25:
            guard let v = buf.readInteger(endianness: .big, as: UInt16.self) else {
                throw CBORError.truncated
            }
            return UInt64(v)
        case 26:
            guard let v = buf.readInteger(endianness: .big, as: UInt32.self) else {
                throw CBORError.truncated
            }
            return UInt64(v)
        case 27:
            guard let v = buf.readInteger(endianness: .big, as: UInt64.self) else {
                throw CBORError.truncated
            }
            return v
        default:
            throw CBORError.unsupportedAdditionalInfo(info)
        }
    }

    private static func writeHead(major: UInt8, info: UInt64, into buf: inout ByteBuffer) {
        let prefix = major << 5
        if info <= 23 {
            buf.writeInteger(prefix | UInt8(info))
        } else if info <= 0xFF {
            buf.writeInteger(prefix | 24)
            buf.writeInteger(UInt8(info))
        } else if info <= 0xFFFF {
            buf.writeInteger(prefix | 25)
            buf.writeInteger(UInt16(info), endianness: .big)
        } else if info <= 0xFFFF_FFFF {
            buf.writeInteger(prefix | 26)
            buf.writeInteger(UInt32(info), endianness: .big)
        } else {
            buf.writeInteger(prefix | 27)
            buf.writeInteger(info, endianness: .big)
        }
    }
}

// MARK: - Errors

enum CBORError: Error, Sendable {
    case truncated
    case typeMismatch(expected: String, got: UInt8)
    case unsupportedMajorType(UInt8)
    case unsupportedAdditionalInfo(UInt8)
}
