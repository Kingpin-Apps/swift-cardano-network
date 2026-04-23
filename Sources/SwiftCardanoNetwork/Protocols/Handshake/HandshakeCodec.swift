import NIOCore

/// Minimal CBOR-based codec for the Handshake mini-protocol.
///
/// The Handshake payload is a tagged CBOR array:
/// - `ProposeVersions`: `[0, {version: versionData, ...}]`
/// - `AcceptVersion`:   `[1, version, versionData]`
/// - `Refuse`:          `[2, refuseReason]`
///
/// `versionData` for NtN: `[networkMagic, diffusionMode]`
/// `versionData` for NtC: `networkMagic` (a bare uint)
///
/// This codec implements a hand-rolled CBOR subset sufficient for the Handshake.
/// When swift-cardano-core is integrated it should replace this implementation.
public struct HandshakeCodec: ProtocolCodec, Sendable {
    public typealias Message = HandshakeMessage

    public enum Mode: Sendable { case nodeToNode, nodeToClient }

    private let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    // MARK: - Encode

    public func encode(_ message: HandshakeMessage, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        var buf = allocator.buffer(capacity: 256)
        switch message {
        case .proposeVersions(let versions):
            // [0, {version: versionData, ...}]
            writeCBORArrayHeader(count: 2, into: &buf)
            writeCBORUInt(0, into: &buf)
            writeCBORMapHeader(count: versions.count, into: &buf)
            for (version, vd) in versions.sorted(by: { $0.key > $1.key }) {
                writeCBORUInt(UInt64(version), into: &buf)
                writeVersionData(vd, into: &buf)
            }

        case .acceptVersion(let version, let vd):
            // [1, version, versionData]
            writeCBORArrayHeader(count: 3, into: &buf)
            writeCBORUInt(1, into: &buf)
            writeCBORUInt(UInt64(version), into: &buf)
            writeVersionData(vd, into: &buf)

        case .refuse(let reason):
            // [2, refuseReason]
            writeCBORArrayHeader(count: 2, into: &buf)
            writeCBORUInt(2, into: &buf)
            writeRefuseReason(reason, into: &buf)
        }
        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> HandshakeMessage {
        var buf = buffer
        defer { buffer = buf }
        // Outer array header [tag, ...]
        let outerLen = try readCBORArrayHeader(from: &buf)
        guard outerLen >= 2 else { throw HandshakeError.malformedMessage }

        let tag = try readCBORUInt(from: &buf)
        switch tag {
        case 0:
            let mapLen = try readCBORMapHeader(from: &buf)
            var versions: [UInt16: HandshakeVersionData] = [:]
            for _ in 0..<mapLen {
                let v = UInt16(try readCBORUInt(from: &buf))
                let vd = try readVersionData(from: &buf)
                versions[v] = vd
            }
            return .proposeVersions(versions)

        case 1:
            let version = UInt16(try readCBORUInt(from: &buf))
            let vd = try readVersionData(from: &buf)
            return .acceptVersion(version, vd)

        case 2:
            let reason = try readRefuseReason(from: &buf)
            return .refuse(reason)

        case 3:
            // msgQueryReply — server sends back its full supported-version table.
            // Not a valid client-state response; surface as a typed error.
            throw HandshakeError.queryReplyReceived

        default:
            throw HandshakeError.unknownMessageTag(tag)
        }
    }

    // MARK: - Private helpers: version data

    private func writeVersionData(_ vd: HandshakeVersionData, into buf: inout ByteBuffer) {
        switch vd {
        case .nodeToNode(let magic, let initiatorOnly, let peerSharing, let query):
            let count = query != nil ? 4 : peerSharing != nil ? 3 : 2
            writeCBORArrayHeader(count: count, into: &buf)
            writeCBORUInt(UInt64(magic), into: &buf)
            writeCBORBool(initiatorOnly, into: &buf)
            if let ps = peerSharing { writeCBORUInt(UInt64(ps), into: &buf) }
            if let q = query { writeCBORBool(q, into: &buf) }
        case .nodeToClient(let magic, let query):
            writeCBORArrayHeader(count: 2, into: &buf)
            writeCBORUInt(UInt64(magic), into: &buf)
            writeCBORBool(query, into: &buf)
        }
    }

    private func readVersionData(from buf: inout ByteBuffer) throws -> HandshakeVersionData {
        switch mode {
        case .nodeToNode:
            let count = try readCBORArrayHeader(from: &buf)
            guard count >= 2 else { throw HandshakeError.malformedVersionData }
            let magic = UInt32(try readCBORUInt(from: &buf))
            let initiatorOnly = try readCBORBool(from: &buf)
            let peerSharing: UInt8? = count >= 3 ? UInt8(try readCBORUInt(from: &buf)) : nil
            let query: Bool? = count >= 4 ? try readCBORBool(from: &buf) : nil
            return .nodeToNode(networkMagic: magic, initiatorOnly: initiatorOnly, peerSharing: peerSharing, query: query)
        case .nodeToClient:
            if peekIsCBORArray(buf) {
                let count = try readCBORArrayHeader(from: &buf)
                let magic = UInt32(try readCBORUInt(from: &buf))
                let query = count >= 2 ? try readCBORBool(from: &buf) : false
                return .nodeToClient(networkMagic: magic, query: query)
            } else {
                let magic = UInt32(try readCBORUInt(from: &buf))
                return .nodeToClient(networkMagic: magic, query: false)
            }
        }
    }

    private func writeRefuseReason(_ reason: RefuseReason, into buf: inout ByteBuffer) {
        switch reason {
        case .versionMismatch(let versions):
            writeCBORArrayHeader(count: 2, into: &buf)
            writeCBORUInt(0, into: &buf)
            writeCBORArrayHeader(count: versions.count, into: &buf)
            versions.forEach { writeCBORUInt(UInt64($0), into: &buf) }
        case .handshakeDecodeError(let v, let msg):
            writeCBORArrayHeader(count: 3, into: &buf)
            writeCBORUInt(1, into: &buf)
            writeCBORUInt(UInt64(v), into: &buf)
            writeCBORText(msg, into: &buf)
        case .refused(let v, let msg):
            writeCBORArrayHeader(count: 3, into: &buf)
            writeCBORUInt(2, into: &buf)
            writeCBORUInt(UInt64(v), into: &buf)
            writeCBORText(msg, into: &buf)
        }
    }

    private func readRefuseReason(from buf: inout ByteBuffer) throws -> RefuseReason {
        let count = try readCBORArrayHeader(from: &buf)
        let tag = try readCBORUInt(from: &buf)
        switch tag {
        case 0:
            let n = count > 1 ? try readCBORArrayHeader(from: &buf) : 0
            var versions: [UInt16] = []
            for _ in 0..<n { versions.append(UInt16(try readCBORUInt(from: &buf))) }
            return .versionMismatch(versions)
        case 1:
            guard count == 3 else { throw HandshakeError.malformedMessage }
            let v = UInt16(try readCBORUInt(from: &buf))
            let msg = try readCBORText(from: &buf)
            return .handshakeDecodeError(v, msg)
        case 2:
            guard count == 3 else { throw HandshakeError.malformedMessage }
            let v = UInt16(try readCBORUInt(from: &buf))
            let msg = try readCBORText(from: &buf)
            return .refused(v, msg)
        default:
            throw HandshakeError.unknownRefuseTag(tag)
        }
    }
}

// MARK: - Minimal CBOR primitives

// These are used only by HandshakeCodec. Replace with swift-cardano-core when available.

private func writeCBORUInt(_ v: UInt64, into buf: inout ByteBuffer) {
    if v <= 23 {
        buf.writeInteger(UInt8(v))
    } else if v <= 0xFF {
        buf.writeInteger(UInt8(0x18))
        buf.writeInteger(UInt8(v))
    } else if v <= 0xFFFF {
        buf.writeInteger(UInt8(0x19))
        buf.writeInteger(UInt16(v), endianness: .big)
    } else if v <= 0xFFFF_FFFF {
        buf.writeInteger(UInt8(0x1A))
        buf.writeInteger(UInt32(v), endianness: .big)
    } else {
        buf.writeInteger(UInt8(0x1B))
        buf.writeInteger(v, endianness: .big)
    }
}

private func writeCBORArrayHeader(count: Int, into buf: inout ByteBuffer) {
    writeCBORUInt(UInt64(count), into: &buf)
    // Patch the major type to 4 (array).
    let idx = buf.writerIndex - (count <= 23 ? 1 : count <= 0xFF ? 2 : count <= 0xFFFF ? 3 : 5)
    let existing = buf.getInteger(at: idx, as: UInt8.self)!
    buf.setInteger(existing | 0x80, at: idx)
}

private func writeCBORMapHeader(count: Int, into buf: inout ByteBuffer) {
    writeCBORUInt(UInt64(count), into: &buf)
    let idx = buf.writerIndex - (count <= 23 ? 1 : count <= 0xFF ? 2 : count <= 0xFFFF ? 3 : 5)
    let existing = buf.getInteger(at: idx, as: UInt8.self)!
    buf.setInteger(existing | 0xA0, at: idx)
}

private func writeCBORBool(_ v: Bool, into buf: inout ByteBuffer) {
    buf.writeInteger(v ? UInt8(0xF5) : UInt8(0xF4))
}

private func writeCBORText(_ s: String, into buf: inout ByteBuffer) {
    let bytes = Array(s.utf8)
    writeCBORUInt(UInt64(bytes.count), into: &buf)
    let idx = buf.writerIndex - (bytes.count <= 23 ? 1 : bytes.count <= 0xFF ? 2 : 3)
    let existing = buf.getInteger(at: idx, as: UInt8.self)!
    buf.setInteger(existing | 0x60, at: idx)
    buf.writeBytes(bytes)
}

// MARK: - Decode helpers

/// Returns true if the next byte is a CBOR array header (major type 4) without consuming it.
private func peekIsCBORArray(_ buf: ByteBuffer) -> Bool {
    guard let b = buf.getInteger(at: buf.readerIndex, as: UInt8.self) else { return false }
    return (b >> 5) == 4
}

private func readCBORByte(from buf: inout ByteBuffer) throws -> UInt8 {
    guard let b = buf.readInteger(as: UInt8.self) else { throw HandshakeError.malformedMessage }
    return b
}

private func readCBORUInt(from buf: inout ByteBuffer) throws -> UInt64 {
    let initial = try readCBORByte(from: &buf)
    let info = initial & 0x1F
    switch info {
    case 0...23: return UInt64(info)
    case 24:
        guard let v = buf.readInteger(as: UInt8.self) else { throw HandshakeError.malformedMessage }
        return UInt64(v)
    case 25:
        guard let v = buf.readInteger(endianness: .big, as: UInt16.self) else { throw HandshakeError.malformedMessage }
        return UInt64(v)
    case 26:
        guard let v = buf.readInteger(endianness: .big, as: UInt32.self) else { throw HandshakeError.malformedMessage }
        return UInt64(v)
    case 27:
        guard let v = buf.readInteger(endianness: .big, as: UInt64.self) else { throw HandshakeError.malformedMessage }
        return v
    default:
        throw HandshakeError.malformedMessage
    }
}

private func readCBORArrayHeader(from buf: inout ByteBuffer) throws -> Int {
    let initial = try readCBORByte(from: &buf)
    guard (initial >> 5) == 4 else { throw HandshakeError.malformedMessage }
    let info = initial & 0x1F
    switch info {
    case 0...23: return Int(info)
    case 24:
        guard let v = buf.readInteger(as: UInt8.self) else { throw HandshakeError.malformedMessage }
        return Int(v)
    case 25:
        guard let v = buf.readInteger(endianness: .big, as: UInt16.self) else { throw HandshakeError.malformedMessage }
        return Int(v)
    default:
        throw HandshakeError.malformedMessage
    }
}

private func readCBORMapHeader(from buf: inout ByteBuffer) throws -> Int {
    let initial = try readCBORByte(from: &buf)
    guard (initial >> 5) == 5 else { throw HandshakeError.malformedMessage }
    let info = initial & 0x1F
    switch info {
    case 0...23: return Int(info)
    case 24:
        guard let v = buf.readInteger(as: UInt8.self) else { throw HandshakeError.malformedMessage }
        return Int(v)
    case 25:
        guard let v = buf.readInteger(endianness: .big, as: UInt16.self) else { throw HandshakeError.malformedMessage }
        return Int(v)
    default:
        throw HandshakeError.malformedMessage
    }
}

private func readCBORBool(from buf: inout ByteBuffer) throws -> Bool {
    let b = try readCBORByte(from: &buf)
    switch b {
    case 0xF4: return false
    case 0xF5: return true
    default: throw HandshakeError.malformedMessage
    }
}

private func readCBORText(from buf: inout ByteBuffer) throws -> String {
    let initial = try readCBORByte(from: &buf)
    guard (initial >> 5) == 3 else { throw HandshakeError.malformedMessage }
    let info = initial & 0x1F
    let length: Int
    switch info {
    case 0...23: length = Int(info)
    case 24:
        guard let v = buf.readInteger(as: UInt8.self) else { throw HandshakeError.malformedMessage }
        length = Int(v)
    case 25:
        guard let v = buf.readInteger(endianness: .big, as: UInt16.self) else { throw HandshakeError.malformedMessage }
        length = Int(v)
    default:
        throw HandshakeError.malformedMessage
    }
    guard let bytes = buf.readBytes(length: length) else { throw HandshakeError.malformedMessage }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}

// MARK: - Errors

public enum HandshakeError: Error, Sendable {
    case malformedMessage
    case malformedVersionData
    case unknownMessageTag(UInt64)
    case unknownRefuseTag(UInt64)
    case refused(RefuseReason)
    /// Server sent msgQueryReply (tag 3) — unexpected in the client state machine.
    case queryReplyReceived
}
