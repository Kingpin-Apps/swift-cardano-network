import Foundation
import OrderedCollections
import SwiftCardanoCore

/// Stake snapshot for a single pool at a single ledger snapshot boundary.
public struct PoolStakeSnapshotEntry: Serializable {
    /// Stake-pool operator (bech32 `pool…` ID; underlying 28-byte key hash).
    public let poolOperator: PoolOperator
    /// Stake at the mark snapshot boundary.
    public let stakeMark: UInt64
    /// Stake at the set snapshot boundary.
    public let stakeSet: UInt64
    /// Stake at the go snapshot boundary.
    public let stakeGo: UInt64

    public init(poolOperator: PoolOperator, stakeMark: UInt64, stakeSet: UInt64, stakeGo: UInt64) {
        self.poolOperator = poolOperator
        self.stakeMark = stakeMark
        self.stakeSet = stakeSet
        self.stakeGo = stakeGo
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolStakeSnapshotEntry: expected [poolOperator, mark, set, go]")
        }
        poolOperator = try PoolOperator(from: f[0])
        stakeMark    = try Self.uintValue(f[1])
        stakeSet     = try Self.uintValue(f[2])
        stakeGo      = try Self.uintValue(f[3])
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try poolOperator.toPrimitive(),
            .uint(UInt(stakeMark)),
            .uint(UInt(stakeSet)),
            .uint(UInt(stakeGo)),
        ])
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("poolOperator")] = try poolOperator.toDict()
        dict[.string("stakeMark")]    = .uint(UInt(stakeMark))
        dict[.string("stakeSet")]     = .uint(UInt(stakeSet))
        dict[.string("stakeGo")]      = .uint(UInt(stakeGo))
        return .orderedDict(dict)
    }

    private static func uintValue(_ p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolStakeSnapshotEntry: expected uint")
        }
    }
}

/// Stake snapshots for all requested pools.
///
/// Returned by `GetStakeSnapshots` (query tag 20).
/// Wire format (pallas): `[{ pool_hash → StakeSnapshot }, mark_total, set_total, go_total]`
/// where `StakeSnapshot = { mark, set, go }` (three UInt64 values in a map or array).
public struct StakeSnapshots: Serializable {
    public let pools: [PoolStakeSnapshotEntry]
    /// Total active stake at the mark boundary.
    public let totalStakeMark: UInt64
    /// Total active stake at the set boundary.
    public let totalStakeSet: UInt64
    /// Total active stake at the go boundary.
    public let totalStakeGo: UInt64

    public init(
        pools: [PoolStakeSnapshotEntry],
        totalStakeMark: UInt64,
        totalStakeSet: UInt64,
        totalStakeGo: UInt64
    ) {
        self.pools = pools
        self.totalStakeMark = totalStakeMark
        self.totalStakeSet = totalStakeSet
        self.totalStakeGo = totalStakeGo
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let elems) = primitive, elems.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat("StakeSnapshots: expected [pool_map, mark, set, go]")
        }

        let poolMap = elems[0]
        let pairs: [(Primitive, Primitive)]
        switch poolMap {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakeSnapshots: expected map for pools")
        }

        pools = try pairs.map { (key, value) in
            let poolOperator = try PoolOperator(from: key)
            guard case .list(let snapshotElems) = value, snapshotElems.count >= 3 else {
                throw LedgerStateDecodingError.unexpectedFormat("StakeSnapshots: expected [mark, set, go] for pool")
            }
            return PoolStakeSnapshotEntry(
                poolOperator: poolOperator,
                stakeMark: try Self.uint(from: snapshotElems[0]),
                stakeSet: try Self.uint(from: snapshotElems[1]),
                stakeGo: try Self.uint(from: snapshotElems[2])
            )
        }
        totalStakeMark = try Self.uint(from: elems[1])
        totalStakeSet = try Self.uint(from: elems[2])
        totalStakeGo = try Self.uint(from: elems[3])
    }

    public func toPrimitive() throws -> Primitive {
        var poolPairs: [(Primitive, Primitive)] = []
        for entry in pools {
            let snapshot = Primitive.list([
                .uint(UInt(entry.stakeMark)),
                .uint(UInt(entry.stakeSet)),
                .uint(UInt(entry.stakeGo)),
            ])
            poolPairs.append((try entry.poolOperator.toPrimitive(), snapshot))
        }
        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: poolPairs)),
            .uint(UInt(totalStakeMark)),
            .uint(UInt(totalStakeSet)),
            .uint(UInt(totalStakeGo)),
        ])
    }

    public func hash(into hasher: inout Hasher) {
        pools.hash(into: &hasher)
        hasher.combine(totalStakeMark)
        hasher.combine(totalStakeSet)
        hasher.combine(totalStakeGo)
    }

    public static func == (lhs: StakeSnapshots, rhs: StakeSnapshots) -> Bool {
        lhs.pools == rhs.pools
            && lhs.totalStakeMark == rhs.totalStakeMark
            && lhs.totalStakeSet == rhs.totalStakeSet
            && lhs.totalStakeGo == rhs.totalStakeGo
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakeSnapshots: expected uint")
        }
    }
}
