import Foundation
import OrderedCollections
import SwiftCardanoCore

/// A single entry mapping a stake pool operator to its total stake.
public struct SPOStakeEntry: Serializable {
    /// Stake-pool operator (bech32 `pool…` ID; underlying 28-byte key hash).
    public let poolOperator: PoolOperator
    /// Total stake delegated to this pool, in lovelace.
    public let stake: UInt64

    public init(poolOperator: PoolOperator, stake: UInt64) {
        self.poolOperator = poolOperator
        self.stake = stake
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "SPOStakeEntry: expected [poolOperator, stake]")
        }
        poolOperator = try PoolOperator(from: f[0])
        switch f[1] {
        case .uint(let v):              stake = UInt64(v)
        case .int(let v) where v >= 0:  stake = UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("SPOStakeEntry: expected uint stake")
        }
    }

    public func toPrimitive() throws -> Primitive {
        .list([try poolOperator.toPrimitive(), .uint(UInt(stake))])
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("poolOperator")] = try poolOperator.toDict()
        dict[.string("stake")]        = .uint(UInt(stake))
        return .orderedDict(dict)
    }
}

/// Map of stake pool operators to their total delegated stake.
///
/// Returned by `GetSPOStakeDistr` (query tag 30).
/// Wire format: `{ pool_key_hash: bytes28 → coin }`
public struct SPOStakeDistribution: Serializable {
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
            let poolOperator = try PoolOperator(from: key)
            let stake = try Self.uint(from: value)
            return SPOStakeEntry(poolOperator: poolOperator, stake: stake)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            pairs.append((try entry.poolOperator.toPrimitive(), .uint(UInt(entry.stake))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: SPOStakeDistribution, rhs: SPOStakeDistribution) -> Bool {
        lhs.entries == rhs.entries
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
