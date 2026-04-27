import NIOCore

/// CBOR codec for the Peer-Sharing mini-protocol (NtN, protocol ID 10, §3.11.7).
///
/// ## Wire format (CDDL ≥ NtN v14)
///
/// ```
/// peerSharingMessage = msgShareRequest
///                    / msgSharePeers
///                    / msgDone
///
/// msgShareRequest = [0, word8]
/// msgSharePeers   = [1, peerAddresses]
/// msgDone         = [2]
///
/// peerAddresses   = [* peerAddress]
/// peerAddress     = [0, word32, portNumber]                              ; ipv4
///                 / [1, word32, word32, word32, word32, portNumber]      ; ipv6
/// portNumber      = word16
/// ```
public struct PeerSharingCodec: ProtocolCodec, Sendable {
    public typealias Message = PeerSharingMessage

    public init() {}

    // MARK: - Encode

    public func encode(_ message: PeerSharingMessage, allocator: ByteBufferAllocator) throws
        -> ByteBuffer
    {
        var buf = allocator.buffer(capacity: 64)

        switch message {
        case .shareRequest(let amount):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            CBORLite.writeUInt(UInt64(amount), into: &buf)

        case .sharePeers(let peers):
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(1, into: &buf)
            CBORLite.writeArrayHeader(count: peers.count, into: &buf)
            for peer in peers {
                writePeerAddress(peer, into: &buf)
            }

        case .done:
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            CBORLite.writeUInt(2, into: &buf)
        }

        return buf
    }

    // MARK: - Decode

    public func decode(_ buffer: inout ByteBuffer) throws -> PeerSharingMessage {
        let arrayLen = try CBORLite.readArrayHeader(from: &buffer)
        let tag      = try CBORLite.readUInt(from: &buffer)

        switch tag {
        case 0:
            guard arrayLen == 2 else { throw PeerSharingError.unexpectedArrayLength(arrayLen) }
            let raw = try CBORLite.readUInt(from: &buffer)
            guard raw <= UInt64(UInt8.max) else {
                throw PeerSharingError.integerOverflow(value: raw, expectedBits: 8)
            }
            return .shareRequest(amount: UInt8(raw))

        case 1:
            guard arrayLen == 2 else { throw PeerSharingError.unexpectedArrayLength(arrayLen) }
            // CDDL `peerAddresses = [* peerAddress]` permits both definite-
            // and indefinite-length encoding (the latter is what real
            // cardano-node relays produce — minicbor emits 9F ... FF for
            // streaming-shape collections).
            let count = try CBORLite.readArrayHeader(from: &buffer)
            var peers: [PeerAddress] = []
            if count == -1 {
                while !CBORLite.peekIsBreak(buffer) {
                    peers.append(try readPeerAddress(from: &buffer))
                }
                CBORLite.skipBreakIfPresent(from: &buffer)
            } else {
                peers.reserveCapacity(count)
                for _ in 0..<count {
                    peers.append(try readPeerAddress(from: &buffer))
                }
            }
            return .sharePeers(peers)

        case 2:
            guard arrayLen == 1 else { throw PeerSharingError.unexpectedArrayLength(arrayLen) }
            return .done

        default:
            throw PeerSharingError.unknownMessageTag(tag)
        }
    }

    // MARK: - Private helpers

    private func writePeerAddress(_ peer: PeerAddress, into buf: inout ByteBuffer) {
        switch peer {
        case .ipv4(let addr, let port):
            CBORLite.writeArrayHeader(count: 3, into: &buf)
            CBORLite.writeUInt(0, into: &buf)
            CBORLite.writeUInt(UInt64(addr), into: &buf)
            CBORLite.writeUInt(UInt64(port), into: &buf)

        case .ipv6(let addr, let port):
            CBORLite.writeArrayHeader(count: 6, into: &buf)
            CBORLite.writeUInt(1, into: &buf)
            CBORLite.writeUInt(UInt64(addr.0), into: &buf)
            CBORLite.writeUInt(UInt64(addr.1), into: &buf)
            CBORLite.writeUInt(UInt64(addr.2), into: &buf)
            CBORLite.writeUInt(UInt64(addr.3), into: &buf)
            CBORLite.writeUInt(UInt64(port), into: &buf)
        }
    }

    private func readPeerAddress(from buf: inout ByteBuffer) throws -> PeerAddress {
        let count = try CBORLite.readArrayHeader(from: &buf)
        let kind  = try CBORLite.readUInt(from: &buf)

        switch kind {
        case 0:
            guard count == 3 else { throw PeerSharingError.unexpectedArrayLength(count) }
            let addr = try readUInt32(from: &buf)
            let port = try readUInt16(from: &buf)
            return .ipv4(addr: addr, port: port)

        case 1:
            guard count == 6 else { throw PeerSharingError.unexpectedArrayLength(count) }
            let w0 = try readUInt32(from: &buf)
            let w1 = try readUInt32(from: &buf)
            let w2 = try readUInt32(from: &buf)
            let w3 = try readUInt32(from: &buf)
            let port = try readUInt16(from: &buf)
            return .ipv6(addr: (w0, w1, w2, w3), port: port)

        default:
            throw PeerSharingError.unknownAddressTag(kind)
        }
    }

    private func readUInt16(from buf: inout ByteBuffer) throws -> UInt16 {
        let raw = try CBORLite.readUInt(from: &buf)
        guard raw <= UInt64(UInt16.max) else {
            throw PeerSharingError.integerOverflow(value: raw, expectedBits: 16)
        }
        return UInt16(raw)
    }

    private func readUInt32(from buf: inout ByteBuffer) throws -> UInt32 {
        let raw = try CBORLite.readUInt(from: &buf)
        guard raw <= UInt64(UInt32.max) else {
            throw PeerSharingError.integerOverflow(value: raw, expectedBits: 32)
        }
        return UInt32(raw)
    }
}
