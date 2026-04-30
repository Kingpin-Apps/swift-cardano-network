import Foundation
import OrderedCollections
import SwiftCardanoCore

/// A single pool's entry in the stake distribution.
public struct PoolDistrEntry: Serializable {
    /// Stake-pool operator (bech32 `pool…` ID; underlying 28-byte key hash).
    public let poolOperator: PoolOperator
    /// Rational numerator of the pool's stake fraction (CBOR tag-30).
    public let stakeNumerator: Int
    /// Rational denominator of the pool's stake fraction (CBOR tag-30).
    public let stakeDenominator: Int
    /// 32-byte VRF verification key hash.
    public let vrfKeyHash: VrfKeyHash
    /// Absolute stake (Lovelace) — populated only for `GetPoolDistr2`
    /// (NtCv21+) responses; nil for the legacy `GetPoolDistr` (pre-v21) path.
    public let absoluteStake: UInt64?

    public init(
        poolOperator: PoolOperator,
        stakeNumerator: Int,
        stakeDenominator: Int,
        vrfKeyHash: VrfKeyHash,
        absoluteStake: UInt64? = nil
    ) {
        self.poolOperator = poolOperator
        self.stakeNumerator = stakeNumerator
        self.stakeDenominator = stakeDenominator
        self.vrfKeyHash = vrfKeyHash
        self.absoluteStake = absoluteStake
    }

    public init(from primitive: Primitive) throws {
        // Wire shape: [stakeFraction, vrfKeyHash] or [stakeFraction, absoluteStake, vrfKeyHash]
        // paired with a poolKeyHash key in the enclosing map. PoolDistrEntry on its
        // own can't be reconstructed without that key; this initializer expects the
        // structured form produced by `toPrimitive()` below.
        guard case .list(let f) = primitive, f.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolDistrEntry: expected [poolKeyHash, stakeFraction, vrfKeyHash, absoluteStake?]")
        }
        poolOperator = try PoolOperator(from: f[0])
        let (num, denom) = try PoolDistr.rationalPair(from: f[1])
        stakeNumerator = num
        stakeDenominator = denom
        vrfKeyHash = try VrfKeyHash(from: f[2])
        if f.count >= 4 {
            switch f[3] {
            case .uint(let u):             absoluteStake = UInt64(u)
            case .int(let i) where i >= 0: absoluteStake = UInt64(i)
            default:                       absoluteStake = nil
            }
        } else {
            absoluteStake = nil
        }
    }

    public func toPrimitive() throws -> Primitive {
        let rational = Primitive.cborTag(
            CBORTag(
                tag: 30,
                value: .list([.int(stakeNumerator), .int(stakeDenominator)])
            )
        )
        var out: [Primitive] = [
            try poolOperator.toPrimitive(),
            rational,
            vrfKeyHash.toPrimitive(),
        ]
        if let abs = absoluteStake { out.append(.uint(UInt(abs))) }
        return .list(out)
    }

    /// Labeled JSON: bech32 pool ID, rational fields, hex VRF, optional stake.
    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("poolOperator")]     = try poolOperator.toDict()
        dict[.string("stakeNumerator")]   = .int(stakeNumerator)
        dict[.string("stakeDenominator")] = .int(stakeDenominator)
        dict[.string("vrfKeyHash")]       = try vrfKeyHash.toDict()
        if let abs = absoluteStake {
            dict[.string("absoluteStake")] = .uint(UInt(abs))
        }
        return .orderedDict(dict)
    }
}

/// Stake distribution across stake pools.
///
/// Returned by either `GetPoolDistr` (tag 21, pre-NtCv21) or
/// `GetPoolDistr2` (tag 36, NtCv21+).  The two response shapes are:
///
/// **Legacy (`GetPoolDistr`)** — bare map:
///     `{ pool_key_hash: bytes28 → [#6.30([num, denom]), vrf_key_hash: bytes32] }`
///
/// **Replacement (`GetPoolDistr2`, ShelleyV13+)** — list[2] wrapper:
///     `[ { pool_key_hash: bytes28 → [unitInterval, absolute_stake: uint, vrf_key_hash] }
///     , total_stake: uint ]`
///
/// Each pool entry's value gained an absolute-stake field at v2 and the
/// outer adds a `totalStake` (sum of every pool's absolute stake).  Both
/// fields are exposed on this struct; for v1 they're nil/0.
public struct PoolDistr: Serializable {
    public let entries: [PoolDistrEntry]
    /// Total active stake across all pools (v2 responses only); nil for v1.
    public let totalStake: UInt64?

    public init(entries: [PoolDistrEntry], totalStake: UInt64? = nil) {
        self.entries = entries
        self.totalStake = totalStake
    }

    public init(from primitive: Primitive) throws {
        // v2 (`GetPoolDistr2`): top is `[mapOfPools, totalStake]`.
        // v1 (`GetPoolDistr`):  top is the map itself.
        let mapPrimitive: Primitive
        let total: UInt64?
        if case .list(let outer) = primitive, outer.count >= 2 {
            mapPrimitive = outer[0]
            switch outer[1] {
            case .uint(let u): total = UInt64(u)
            case .int(let i) where i >= 0: total = UInt64(i)
            default: total = nil
            }
        } else {
            mapPrimitive = primitive
            total = nil
        }

        let pairs: [(Primitive, Primitive)]
        switch mapPrimitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        case .indefiniteDictionary(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected map")
        }
        totalStake = total
        entries = try pairs.map { (key, value) in
            let poolOperator = try PoolOperator(from: key)
            guard case .list(let elems) = value, elems.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected list value")
            }
            let (num, denom) = try Self.rationalPair(from: elems[0])
            // v2 has 3 elements: [unitInterval, absoluteStake: uint, vrf_hash]
            // v1 has 2 elements: [unitInterval-or-tag-30,                vrf_hash]
            let absoluteStake: UInt64?
            let vrfPrimitive: Primitive
            if elems.count >= 3 {
                switch elems[1] {
                case .uint(let u): absoluteStake = UInt64(u)
                case .int(let i) where i >= 0: absoluteStake = UInt64(i)
                default: absoluteStake = nil
                }
                vrfPrimitive = elems[2]
            } else {
                absoluteStake = nil
                vrfPrimitive = elems[1]
            }
            let vrfKeyHash = try VrfKeyHash(from: vrfPrimitive)
            return PoolDistrEntry(
                poolOperator: poolOperator,
                stakeNumerator: num,
                stakeDenominator: denom,
                vrfKeyHash: vrfKeyHash,
                absoluteStake: absoluteStake
            )
        }
    }

    public func toPrimitive() throws -> Primitive {
        var dict: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = try entry.poolOperator.toPrimitive()
            let rational = Primitive.cborTag(
                CBORTag(
                    tag: 30,
                    value: .list([.int(entry.stakeNumerator), .int(entry.stakeDenominator)])
                )
            )
            let value: Primitive
            if let absStake = entry.absoluteStake {
                // v2: [rational, absolute_stake, vrf_key_hash]
                value = .list([rational, .uint(UInt(absStake)), entry.vrfKeyHash.toPrimitive()])
            } else {
                // v1: [rational, vrf_key_hash]
                value = .list([rational, entry.vrfKeyHash.toPrimitive()])
            }
            dict.append((key, value))
        }
        let map = Primitive.frozenDict(Dictionary(uniqueKeysWithValues: dict))
        if let total = totalStake {
            return .list([map, .uint(UInt(total))])
        }
        return map
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: PoolDistr, rhs: PoolDistr) -> Bool {
        lhs.entries == rhs.entries
    }

    static func rationalPair(from p: Primitive) throws -> (Int, Int) {
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

    static func intValue(_ p: Primitive) throws -> Int {
        switch p {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolDistr: expected integer in rational")
        }
    }
}
