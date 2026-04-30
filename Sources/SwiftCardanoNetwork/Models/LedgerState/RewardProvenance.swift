import Foundation
import SwiftCardanoCore

// MARK: - PoolRewardInfo

/// Per-pool reward provenance detail for a single pool.
///
/// Wire format: a CBOR list of 10 elements in Haskell `ToCBOR` order
/// (`RewardProvenancePool`):
///   [0]  poolBlocks          — `Natural` (block count)
///   [1]  sigma               — tag-30 `Rational` (relative stake)
///   [2]  sigmaApparent       — tag-30 `Rational` (apparent relative stake)
///   [3]  ownerStake          — `Coin`
///   [4]  poolParams          — `PoolParams`
///   [5]  pledgeRatio         — tag-30 `Rational`
///   [6]  maxReward           — `Coin`
///   [7]  apparentPerformance — tag-30 `UnitInterval`
///   [8]  poolRewardPot       — `Coin`
///   [9]  leaderReward        — `Coin`
public struct PoolRewardInfo: Serializable {
    /// Number of blocks produced by this pool in the epoch.
    public let poolBlocks: UInt64
    /// Pool's relative stake (sigma = pool stake / total active stake).
    public let sigma: Fraction
    /// Pool's apparent relative stake (adjusted for non-myopic effects).
    public let sigmaApparent: Fraction
    /// Owner's contributed stake in lovelace.
    public let ownerStake: UInt64
    /// Registered pool parameters at the time of the reward calculation.
    public let poolParams: PoolParams?
    /// Pledge ratio for pool desirability ranking.
    public let pledgeRatio: Fraction
    /// Maximum reward the pool can receive in lovelace.
    public let maxReward: UInt64
    /// Apparent performance as a unit interval.
    public let apparentPerformance: Fraction
    /// Pool's reward pot per protocol rules.
    public let poolRewardPot: UInt64
    /// Leader reward amount in lovelace.
    public let leaderReward: UInt64

    /// Raw pool parameters primitive, retained for round-trip fidelity when
    /// `poolParams` could not be decoded.
    public let rawPoolParams: Primitive

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 10 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolRewardInfo: expected list of 10+ elements")
        }
        poolBlocks          = try Self.readUInt64(f[0], label: "poolBlocks")
        sigma               = try Self.readFraction(f[1], label: "sigma")
        sigmaApparent       = try Self.readFraction(f[2], label: "sigmaApparent")
        ownerStake          = try Self.readUInt64(f[3], label: "ownerStake")
        rawPoolParams       = f[4]
        poolParams          = try? PoolParams(from: f[4])
        pledgeRatio         = try Self.readFraction(f[5], label: "pledgeRatio")
        maxReward           = try Self.readUInt64(f[6], label: "maxReward")
        apparentPerformance = try Self.readFraction(f[7], label: "apparentPerformance")
        poolRewardPot       = try Self.readUInt64(f[8], label: "poolRewardPot")
        leaderReward        = try Self.readUInt64(f[9], label: "leaderReward")
    }

    public func toPrimitive() throws -> Primitive {
        let paramsPrimitive: Primitive
        if let pp = poolParams {
            paramsPrimitive = try pp.toPrimitive()
        } else {
            paramsPrimitive = rawPoolParams
        }
        return .list([
            .uint(UInt(poolBlocks)),
            try sigma.toPrimitive(),
            try sigmaApparent.toPrimitive(),
            .uint(UInt(ownerStake)),
            paramsPrimitive,
            try pledgeRatio.toPrimitive(),
            .uint(UInt(maxReward)),
            try apparentPerformance.toPrimitive(),
            .uint(UInt(poolRewardPot)),
            .uint(UInt(leaderReward)),
        ])
    }

    private static func readUInt64(_ prim: Primitive, label: String) throws -> UInt64 {
        switch prim {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolRewardInfo: expected uint for \(label), got \(prim)")
        }
    }

    private static func readFraction(_ prim: Primitive, label: String) throws -> Fraction {
        if case .unitInterval(let ui) = prim {
            return Fraction(numerator: Int(ui.numerator), denominator: Int(ui.denominator))
        }
        if case .cborTag(let tag) = prim, tag.tag == 30,
           case .list(let elems) = tag.value, elems.count == 2 {
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
        throw LedgerStateDecodingError.unexpectedFormat(
            "PoolRewardInfo: expected rational for \(label), got \(prim)")
    }

    private static func readInt(_ prim: Primitive, label: String) throws -> Int {
        switch prim {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolRewardInfo: expected integer for \(label)")
        }
    }
}

extension PoolRewardInfo: Equatable {
    public static func == (lhs: PoolRewardInfo, rhs: PoolRewardInfo) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
}

extension PoolRewardInfo: Hashable {
    public func hash(into hasher: inout Hasher) {
        poolBlocks.hash(into: &hasher)
        poolRewardPot.hash(into: &hasher)
    }
}

// MARK: - RewardProvenance

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
///   [14] pools             — `{ pool_key_hash → PoolRewardInfo }`
///   [15] desirabilities    — `{ pool_key_hash → Double }`
///
/// On many node configurations this query returns an essentially empty/zeroed response;
/// the decoder tolerates that case.
public struct RewardProvenance: Serializable {
    public let slotsPerEpoch: UInt64
    /// Block counts per pool for this epoch.
    public let blocksPerPool: [Data: UInt64]
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
    /// Per-pool detailed reward provenance.
    public let pools: [Data: PoolRewardInfo]
    /// Per-pool desirability scores.
    public let desirabilities: [Data: Double]

    public init(
        slotsPerEpoch: UInt64,
        blocksPerPool: [Data: UInt64],
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
        pools: [Data: PoolRewardInfo],
        desirabilities: [Data: Double]
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
        blocksPerPool      = try Self.readUInt64Map(f[1], label: "blocksPerPool")
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
        pools              = try Self.readPoolRewardInfoMap(f[14], label: "pools")
        desirabilities     = try Self.readDoubleMap(f[15], label: "desirabilities")
    }

    public func toPrimitive() throws -> Primitive {
        var blocksPairs: [(Primitive, Primitive)] = []
        for (k, v) in blocksPerPool {
            blocksPairs.append((.bytes(k), .uint(UInt(v))))
        }
        var poolsPairs: [(Primitive, Primitive)] = []
        for (k, v) in pools {
            poolsPairs.append((.bytes(k), try v.toPrimitive()))
        }
        var desirePairs: [(Primitive, Primitive)] = []
        for (k, v) in desirabilities {
            desirePairs.append((.bytes(k), .float(v)))
        }
        return .list([
            .uint(UInt(slotsPerEpoch)),
            .frozenDict(Dictionary(uniqueKeysWithValues: blocksPairs)),
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
            .frozenDict(Dictionary(uniqueKeysWithValues: poolsPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: desirePairs)),
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

    // MARK: - Private helpers

    private static func readUInt64(_ prim: Primitive, label: String) throws -> UInt64 {
        switch prim {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected uint for \(label), got \(prim)")
        }
    }

    private static func readBytes(_ prim: Primitive, label: String) throws -> Data {
        switch prim {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected bytes for \(label)")
        }
    }

    private static func readUInt64Map(_ prim: Primitive, label: String) throws -> [Data: UInt64] {
        let pairs: [(Primitive, Primitive)]
        switch prim {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected map for \(label)")
        }
        var out: [Data: UInt64] = [:]
        for (k, v) in pairs {
            let hash = try readBytes(k, label: "\(label) key")
            let count = try readUInt64(v, label: "\(label) value")
            out[hash] = count
        }
        return out
    }

    private static func readPoolRewardInfoMap(
        _ prim: Primitive, label: String
    ) throws -> [Data: PoolRewardInfo] {
        let pairs: [(Primitive, Primitive)]
        switch prim {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected map for \(label)")
        }
        var out: [Data: PoolRewardInfo] = [:]
        for (k, v) in pairs {
            let hash = try readBytes(k, label: "\(label) key")
            let info = try PoolRewardInfo(from: v)
            out[hash] = info
        }
        return out
    }

    private static func readDoubleMap(_ prim: Primitive, label: String) throws -> [Data: Double] {
        let pairs: [(Primitive, Primitive)]
        switch prim {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected map for \(label)")
        }
        var out: [Data: Double] = [:]
        for (k, v) in pairs {
            let hash = try readBytes(k, label: "\(label) key")
            let d: Double
            switch v {
            case .float(let f): d = f
            case .uint(let u):  d = Double(u)
            case .int(let i):   d = Double(i)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "RewardProvenance: expected number for \(label) value, got \(v)")
            }
            out[hash] = d
        }
        return out
    }

    private static func readFraction(_ prim: Primitive, label: String) throws -> Fraction {
        if case .unitInterval(let ui) = prim {
            return Fraction(numerator: Int(ui.numerator), denominator: Int(ui.denominator))
        }
        if case .cborTag(let tag) = prim, tag.tag == 30,
           case .list(let elems) = tag.value, elems.count == 2 {
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
        throw LedgerStateDecodingError.unexpectedFormat(
            "RewardProvenance: expected rational for \(label), got \(prim)")
    }

    private static func readInt(_ prim: Primitive, label: String) throws -> Int {
        switch prim {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardProvenance: expected integer for \(label)")
        }
    }
}
