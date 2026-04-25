import Foundation
import SwiftCardanoCore

/// A single entry mapping a stake pool operator to its total stake.
public struct SPOStakeEntry: Sendable, Equatable, Hashable {
    /// 28-byte pool key hash.
    public let poolKeyHash: Data
    /// Total stake delegated to this pool, in lovelace.
    public let stake: UInt64

    public init(poolKeyHash: Data, stake: UInt64) {
        self.poolKeyHash = poolKeyHash
        self.stake = stake
    }
}

/// Map of stake pool operators to their total delegated stake.
///
/// Returned by `GetSPOStakeDistr` (query tag 30).
/// Wire format: `{ pool_key_hash: bytes28 → coin }`
public struct SPOStakeDistribution: CBORSerializable, Sendable {
    public let entries: [SPOStakeEntry]

    public init(entries: [SPOStakeEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("SPOStakeDistribution: expected map")
        }
        entries = try pairs.map { (key, value) in
            let poolKeyHash = try Self.bytes(from: key)
            let stake = try Self.uint(from: value)
            return SPOStakeEntry(poolKeyHash: poolKeyHash, stake: stake)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            pairs.append((.bytes(entry.poolKeyHash), .uint(UInt(entry.stake))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: SPOStakeDistribution, rhs: SPOStakeDistribution) -> Bool {
        lhs.entries == rhs.entries
    }

    private static func bytes(from p: Primitive) throws -> Data {
        switch p {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("SPOStakeDistribution: expected bytes for pool key hash")
        }
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("SPOStakeDistribution: expected uint for stake")
        }
    }
}
