import NIOCore

// MARK: - Primitive types

/// A 32-byte block header hash.
public typealias BlockHash = [UInt8]

/// A point on the chain: either the genesis origin or a concrete (slot, hash) pair.
public enum Point: Sendable, Equatable {
    case origin
    case blockPoint(slot: UInt64, hash: BlockHash)
}

extension Point: CustomStringConvertible {
    public var description: String {
        switch self {
        case .origin:                        return "origin"
        case .blockPoint(let s, let h):      return "(\(s), \(h.hexString))"
        }
    }
}

/// The last known tip reported by the server.
public struct Tip: Sendable {
    public let point: Point
    public let blockNo: UInt64

    public init(point: Point, blockNo: UInt64) {
        self.point = point
        self.blockNo = blockNo
    }
}

/// The raw block (or header) carried in a `RollForward` message.
///
/// `era` follows the Cardano era numbering:
/// ```
/// Byron=0  Shelley=1  Allegra=2  Mary=3  Alonzo=4  Babbage=5  Conway=6
/// ```
/// `rawCBOR` is the serialised block body. Decode with `swift-cardano-core`.
public struct RawBlock: @unchecked Sendable {
    public let era: UInt64
    public var rawCBOR: ByteBuffer

    public init(era: UInt64, rawCBOR: ByteBuffer) {
        self.era = era
        self.rawCBOR = rawCBOR
    }
}

// MARK: - ChainSync messages

/// The complete ChainSync mini-protocol message set (NtN and NtC).
///
/// `HeaderOrBlock` is `RawBlock` in both cases: for NtN the payload is a block
/// header; for NtC it is a full block. Callers distinguish by the `mode` they
/// configured on `ChainSyncClient`.
public enum ChainSyncMessage: Sendable {
    // Client → Server
    case requestNext
    case findIntersect([Point])
    case done

    // Server → Client
    case awaitReply
    case rollForward(RawBlock, Tip)
    case rollBackward(Point, Tip)
    case intersectFound(Point, Tip)
    case intersectNotFound(Tip)
}

// MARK: - Helpers

private extension [UInt8] {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
