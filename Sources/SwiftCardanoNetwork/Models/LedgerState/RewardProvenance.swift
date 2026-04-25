import Foundation
import SwiftCardanoCore

/// Per-pool reward provenance detail (kept opaque).
public struct PoolRewardProvenanceEntry: Sendable, Equatable, Hashable {
    /// SHA2-256 hash of the pool's cold verification key (28 bytes).
    public let poolKeyHash: Data
    /// Raw CBOR primitive for this pool's reward provenance detail.
    public let primitive: Primitive

    public init(poolKeyHash: Data, primitive: Primitive) {
        self.poolKeyHash = poolKeyHash
        self.primitive = primitive
    }
}

/// Detailed reward provenance data for the current epoch.
///
/// Returned by `GetRewardProvenance` (query tag 14).
///
/// Wire format (cardano-ledger `RewardProvenance`): a CBOR list of 16 elements
/// in Haskell ToCBOR order:
///   [0]  slotsPerEpoch     — `UInt64`
///   [1]  blocksPerPool     — `{ pool_key_hash → block_count }`
///   [2]  maxBlockBodySize  — `UInt64`
///   [3]  maxBlockHeaderSize— `UInt64`
///   [4]  maxLovelaceSupply — `UInt64`
///   [5]  activeStake       — `UInt64`
///   [6]  totalStake        — `UInt64`
///   [7]  totalBlocks       — `UInt64`
///   [8]  decentralisation  — tag-30 `Fraction`
///   [9]  expectedBlocks    — `UInt64`
///   [10] eta               — tag-30 `Fraction` (apparent performance)
///   [11] rewardPot         — `UInt64`
///   [12] deltaR1           — `UInt64`
///   [13] deltaR2           — `UInt64`
///   [14] pools             — `{ pool_key_hash → pool_reward_provenance }`
///   [15] desirabilities    — `{ pool_key_hash → desirability }`
///
/// On many node configurations this query returns an essentially empty/zeroed response;
/// the decoder tolerates that case.
public struct RewardProvenance: CBORSerializable, Sendable {
    public let slotsPerEpoch: UInt64
    public let blocksPerPool: [PoolRewardProvenanceEntry]
    public let maxBlockBodySize: UInt64
    public let maxBlockHeaderSize: UInt64
    public let maxLovelaceSupply: UInt64
    public let activeStake: UInt64
    public let totalStake: UInt64
    public let totalBlocks: UInt64
    public let decentralisation: Fraction
    public let expectedBlocks: UInt64
    public let eta: Fraction
    public let rewardPot: UInt64
    public let deltaR1: UInt64
    public let deltaR2: UInt64
    public let pools: [PoolRewardProvenanceEntry]
    public let desirabilities: [PoolRewardProvenanceEntry]

    public init(
        slotsPerEpoch: UInt64,
        blocksPerPool: [PoolRewardProvenanceEntry],
        maxBlockBodySize: UInt64,
        maxBlockHeaderSize: UInt64,
        maxLovelaceSupply: UInt64,
        activeStake: UInt64,
        totalStake: UInt64,
        totalBlocks: UInt64,
        decentralisation: Fraction,
        expectedBlocks: UInt64,
        eta: Fraction,
        rewardPot: UInt64,
        deltaR1: UInt64,
        deltaR2: UInt64,
        pools: [PoolRewardProvenanceEntry],
        desirabilities: [PoolRewardProvenanceEntry]
    ) {
        self.slotsPerEpoch = slotsPerEpoch
        self.blocksPerPool = blocksPerPool
        self.maxBlockBodySize = maxBlockBodySize
        self.maxBlockHeaderSize = maxBlockHeaderSize
        self.maxLovelaceSupply = maxLovelaceSupply
        self.activeStake = activeStake
        self.totalStake = totalStake
        self.totalBlocks = totalBlocks
        self.decentralisation = decentralisation
        self.expectedBlocks = expectedBlocks
        self.eta = eta
        self.rewardPot = rewardPot
        self.deltaR1 = deltaR1
        self.deltaR2 = deltaR2
        self.pools = pools
        self.desirabilities = desirabilities
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 16 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected list of 16+ elements, got \(primitive)")
        }

        slotsPerEpoch      = try Self.readUInt64(f[0],  label: "slotsPerEpoch")
        blocksPerPool      = try Self.readPoolMap(f[1], label: "blocksPerPool")
        maxBlockBodySize   = try Self.readUInt64(f[2],  label: "maxBlockBodySize")
        maxBlockHeaderSize = try Self.readUInt64(f[3],  label: "maxBlockHeaderSize")
        maxLovelaceSupply  = try Self.readUInt64(f[4],  label: "maxLovelaceSupply")
        activeStake        = try Self.readUInt64(f[5],  label: "activeStake")
        totalStake         = try Self.readUInt64(f[6],  label: "totalStake")
        totalBlocks        = try Self.readUInt64(f[7],  label: "totalBlocks")
        decentralisation   = try Self.readFraction(f[8], label: "decentralisation")
        expectedBlocks     = try Self.readUInt64(f[9],  label: "expectedBlocks")
        eta                = try Self.readFraction(f[10], label: "eta")
        rewardPot          = try Self.readUInt64(f[11], label: "rewardPot")
        deltaR1            = try Self.readUInt64(f[12], label: "deltaR1")
        deltaR2            = try Self.readUInt64(f[13], label: "deltaR2")
        pools              = try Self.readPoolMap(f[14], label: "pools")
        desirabilities     = try Self.readPoolMap(f[15], label: "desirabilities")
    }

    public func toPrimitive() throws -> Primitive {
        let blocksPrim = try Self.encodePoolMap(blocksPerPool, encodeValue: { .uint(UInt($0)) }, label: "blocksPerPool")
        let poolsPrim = Self.encodePoolPrimMap(pools)
        let desirabilitiesPrim = Self.encodePoolPrimMap(desirabilities)
        return .list([
            .uint(UInt(slotsPerEpoch)),
            blocksPrim,
            .uint(UInt(maxBlockBodySize)),
            .uint(UInt(maxBlockHeaderSize)),
            .uint(UInt(maxLovelaceSupply)),
            .uint(UInt(activeStake)),
            .uint(UInt(totalStake)),
            .uint(UInt(totalBlocks)),
            try decentralisation.toPrimitive(),
            .uint(UInt(expectedBlocks)),
            try eta.toPrimitive(),
            .uint(UInt(rewardPot)),
            .uint(UInt(deltaR1)),
            .uint(UInt(deltaR2)),
            poolsPrim,
            desirabilitiesPrim,
        ])
    }

    public static func == (lhs: RewardProvenance, rhs: RewardProvenance) -> Bool {
        lhs.slotsPerEpoch == rhs.slotsPerEpoch
            && lhs.totalBlocks == rhs.totalBlocks
            && lhs.activeStake == rhs.activeStake
            && lhs.totalStake == rhs.totalStake
            && lhs.pools == rhs.pools
    }

    public func hash(into hasher: inout Hasher) {
        slotsPerEpoch.hash(into: &hasher)
        totalBlocks.hash(into: &hasher)
        pools.hash(into: &hasher)
    }

    private static func readUInt64(_ prim: Primitive, label: String) throws -> UInt64 {
        switch prim {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardProvenance: expected uint for \(label), got \(prim)")
        }
    }

    private static func readBytes(_ prim: Primitive, label: String) throws -> Data {
        switch prim {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardProvenance: expected bytes for \(label)")
        }
    }

    private static func readPoolMap(_ prim: Primitive, label: String) throws -> [PoolRewardProvenanceEntry] {
        let pairs: [(Primitive, Primitive)]
        switch prim {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardProvenance: expected map for \(label)")
        }
        return try pairs.map { (k, v) in
            PoolRewardProvenanceEntry(poolKeyHash: try readBytes(k, label: "\(label) key"), primitive: v)
        }
    }

    private static func readFraction(_ prim: Primitive, label: String) throws -> Fraction {
        if case .unitInterval(let ui) = prim {
            return Fraction(numerator: Int(ui.numerator), denominator: Int(ui.denominator))
        }
        if case .cborTag(let tag) = prim, tag.tag == 30, case .list(let elems) = tag.value, elems.count == 2 {
            return Fraction(
                numerator: try readInt(elems[0], label: "\(label).numerator"),
                denominator: try readInt(elems[1], label: "\(label).denominator")
            )
        }
        if case .list(let elems) = prim, elems.count == 2 {
            return Fraction(
                numerator: try readInt(elems[0], label: "\(label).numerator"),
                denominator: try readInt(elems[1], label: "\(label).denominator")
            )
        }
        throw LedgerStateDecodingError.unexpectedFormat("RewardProvenance: expected rational for \(label), got \(prim)")
    }

    private static func readInt(_ prim: Primitive, label: String) throws -> Int {
        switch prim {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardProvenance: expected integer for \(label)")
        }
    }

    private static func encodePoolMap(
        _ entries: [PoolRewardProvenanceEntry],
        encodeValue: (UInt64) -> Primitive,
        label: String
    ) throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            guard case .uint(let v) = entry.primitive else {
                throw LedgerStateDecodingError.unexpectedFormat("RewardProvenance: expected uint primitive in \(label)")
            }
            pairs.append((.bytes(entry.poolKeyHash), encodeValue(UInt64(v))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    private static func encodePoolPrimMap(_ entries: [PoolRewardProvenanceEntry]) -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            pairs.append((.bytes(entry.poolKeyHash), entry.primitive))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }
}
