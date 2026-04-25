import Foundation
import SwiftCardanoCore

/// A single pool's entry in the stake distribution.
public struct PoolDistrEntry: Sendable, Equatable, Hashable {
    /// 28-byte pool key hash.
    public let poolKeyHash: Data
    /// Rational numerator of the pool's stake fraction (CBOR tag-30).
    public let stakeNumerator: Int
    /// Rational denominator of the pool's stake fraction (CBOR tag-30).
    public let stakeDenominator: Int
    /// 32-byte VRF verification key hash.
    public let vrfKeyHash: Data

    public init(
        poolKeyHash: Data,
        stakeNumerator: Int,
        stakeDenominator: Int,
        vrfKeyHash: Data
    ) {
        self.poolKeyHash = poolKeyHash
        self.stakeNumerator = stakeNumerator
        self.stakeDenominator = stakeDenominator
        self.vrfKeyHash = vrfKeyHash
    }
}

/// Stake distribution across stake pools.
///
/// Returned by `GetPoolDistr` (query tag 21).
/// Wire format: `{ pool_key_hash: bytes28 → [#6.30([numerator, denominator]), vrf_key_hash: bytes32] }`
public struct PoolDistr: CBORSerializable, Sendable {
    public let entries: [PoolDistrEntry]

    public init(entries: [PoolDistrEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected map")
        }
        entries = try pairs.map { (key, value) in
            let poolKeyHash = try Self.bytes(from: key, context: "pool key hash")
            guard case .list(let elems) = value, elems.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected [rational, vrf_hash]")
            }
            let (num, denom) = try Self.rational(from: elems[0])
            let vrfKeyHash = try Self.bytes(from: elems[1], context: "VRF key hash")
            return PoolDistrEntry(
                poolKeyHash: poolKeyHash,
                stakeNumerator: num,
                stakeDenominator: denom,
                vrfKeyHash: vrfKeyHash
            )
        }
    }

    public func toPrimitive() throws -> Primitive {
        var dict: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = Primitive.bytes(entry.poolKeyHash)
            let rational = Primitive.cborTag(
                CBORTag(
                    tag: 30,
                    value: .list([.int(entry.stakeNumerator), .int(entry.stakeDenominator)])
                )
            )
            let value = Primitive.list([rational, .bytes(entry.vrfKeyHash)])
            dict.append((key, value))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: dict))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: PoolDistr, rhs: PoolDistr) -> Bool {
        lhs.entries == rhs.entries
    }

    private static func bytes(from p: Primitive, context: String) throws -> Data {
        switch p {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected bytes for \(context)")
        }
    }

    private static func rational(from p: Primitive) throws -> (Int, Int) {
        // swift-cardano-core decodes CBOR tag-30 (rational) as Primitive.unitInterval
        if case .unitInterval(let ui) = p {
            return (Int(ui.numerator), Int(ui.denominator))
        }
        // Fallback: explicit cborTag(30, [num, denom])
        if case .cborTag(let tag) = p, tag.tag == 30 {
            if case .list(let elems) = tag.value, elems.count == 2 {
                return (try intValue(elems[0]), try intValue(elems[1]))
            }
        }
        // Bare [num, denom] without tag
        if case .list(let elems) = p, elems.count == 2 {
            return (try intValue(elems[0]), try intValue(elems[1]))
        }
        throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: unexpected rational primitive: \(p)")
    }

    private static func intValue(_ p: Primitive) throws -> Int {
        switch p {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected integer in rational")
        }
    }
}
