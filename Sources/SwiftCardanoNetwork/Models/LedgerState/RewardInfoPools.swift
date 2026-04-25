import Foundation
import SwiftCardanoCore

/// Global epoch-level reward parameters.
///
/// Wire format: a CBOR list of 4 elements `[nopt, a0, rPot, totalStake]`.
public struct RewardGlobalInfo: Sendable, Equatable, Hashable {
    /// Desired number of pools (`nopt` / `k` parameter).
    public let desiredNumberOfPools: UInt64
    /// Pool influence factor (`a0`, tag-30 fraction).
    public let poolInfluence: Fraction
    /// Total reward pot available this epoch (lovelace).
    public let totalRewardPot: UInt64
    /// Total active stake this epoch (lovelace).
    public let totalStake: UInt64

    public init(
        desiredNumberOfPools: UInt64,
        poolInfluence: Fraction,
        totalRewardPot: UInt64,
        totalStake: UInt64
    ) {
        self.desiredNumberOfPools = desiredNumberOfPools
        self.poolInfluence = poolInfluence
        self.totalRewardPot = totalRewardPot
        self.totalStake = totalStake
    }
}

/// Per-pool reward information for a single pool.
///
/// Wire format: a CBOR list of 6 elements
/// `[stake, ownerPledge, ownerStake, cost, margin, performanceEstimate]`.
public struct PerPoolRewardInfo: Sendable, Equatable, Hashable {
    /// SHA2-256 hash of the pool's cold verification key (28 bytes).
    public let poolKeyHash: Data
    /// Total stake delegated to this pool (lovelace).
    public let stake: UInt64
    /// Declared owner pledge (lovelace).
    public let ownerPledge: UInt64
    /// Stake currently provided by pool owners (lovelace).
    public let ownerStake: UInt64
    /// Declared fixed cost (lovelace).
    public let cost: UInt64
    /// Declared margin (tag-30 fraction).
    public let margin: Fraction
    /// Apparent performance estimate (CBOR double).
    public let performanceEstimate: Double

    public init(
        poolKeyHash: Data,
        stake: UInt64,
        ownerPledge: UInt64,
        ownerStake: UInt64,
        cost: UInt64,
        margin: Fraction,
        performanceEstimate: Double
    ) {
        self.poolKeyHash = poolKeyHash
        self.stake = stake
        self.ownerPledge = ownerPledge
        self.ownerStake = ownerStake
        self.cost = cost
        self.margin = margin
        self.performanceEstimate = performanceEstimate
    }
}

/// Per-pool reward information for the current epoch.
///
/// Returned by `GetRewardInfoPools` (query tag 18).
///
/// Wire format: `[globalInfo, pools]` where:
/// - `globalInfo`: list[4] `[nopt, a0, rPot, totalStake]`
/// - `pools`: `{ pool_key_hash → list[6] [stake, ownerPledge, ownerStake, cost, margin, performance] }`
public struct RewardInfoPools: CBORSerializable, Sendable {
    /// Global epoch-level reward parameters.
    public let globalInfo: RewardGlobalInfo
    /// Per-pool reward information for this epoch.
    public let pools: [PerPoolRewardInfo]

    public init(globalInfo: RewardGlobalInfo, pools: [PerPoolRewardInfo]) {
        self.globalInfo = globalInfo
        self.pools = pools
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let outer) = primitive, outer.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardInfoPools: expected [globalInfo, pools]")
        }

        guard case .list(let g) = outer[0], g.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "RewardInfoPools: globalInfo must be a list of 4 elements")
        }
        globalInfo = RewardGlobalInfo(
            desiredNumberOfPools: try Self.readUInt64(g[0], label: "desiredNumberOfPools"),
            poolInfluence:        try Self.readFraction(g[1], label: "poolInfluence"),
            totalRewardPot:       try Self.readUInt64(g[2], label: "totalRewardPot"),
            totalStake:           try Self.readUInt64(g[3], label: "totalStake")
        )

        let pairs: [(Primitive, Primitive)]
        switch outer[1] {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardInfoPools: expected map for pools")
        }

        pools = try pairs.map { (key, value) in
            let hash = try Self.readBytes(key, label: "pool key hash")
            guard case .list(let p) = value, p.count >= 6 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "RewardInfoPools: per-pool entry must be a list of 6 elements")
            }
            return PerPoolRewardInfo(
                poolKeyHash:         hash,
                stake:               try Self.readUInt64(p[0], label: "stake"),
                ownerPledge:         try Self.readUInt64(p[1], label: "ownerPledge"),
                ownerStake:          try Self.readUInt64(p[2], label: "ownerStake"),
                cost:                try Self.readUInt64(p[3], label: "cost"),
                margin:              try Self.readFraction(p[4], label: "margin"),
                performanceEstimate: try Self.readDouble(p[5], label: "performanceEstimate")
            )
        }
    }

    public func toPrimitive() throws -> Primitive {
        let g = globalInfo
        let globalPrim: Primitive = .list([
            .uint(UInt(g.desiredNumberOfPools)),
            try g.poolInfluence.toPrimitive(),
            .uint(UInt(g.totalRewardPot)),
            .uint(UInt(g.totalStake)),
        ])

        var poolPairs: [(Primitive, Primitive)] = []
        for p in pools {
            let poolPrim: Primitive = .list([
                .uint(UInt(p.stake)),
                .uint(UInt(p.ownerPledge)),
                .uint(UInt(p.ownerStake)),
                .uint(UInt(p.cost)),
                try p.margin.toPrimitive(),
                .float(p.performanceEstimate),
            ])
            poolPairs.append((.bytes(p.poolKeyHash), poolPrim))
        }

        return .list([globalPrim, .frozenDict(Dictionary(uniqueKeysWithValues: poolPairs))])
    }

    public static func == (lhs: RewardInfoPools, rhs: RewardInfoPools) -> Bool {
        lhs.globalInfo == rhs.globalInfo && lhs.pools == rhs.pools
    }

    public func hash(into hasher: inout Hasher) {
        globalInfo.hash(into: &hasher)
        pools.hash(into: &hasher)
    }

    private static func readUInt64(_ prim: Primitive, label: String) throws -> UInt64 {
        switch prim {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardInfoPools: expected uint for \(label)")
        }
    }

    private static func readBytes(_ prim: Primitive, label: String) throws -> Data {
        switch prim {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardInfoPools: expected bytes for \(label)")
        }
    }

    /// Decode a tag-30 rational that may surface as `.unitInterval`, `.cborTag(30)`, or a bare list.
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
        throw LedgerStateDecodingError.unexpectedFormat("RewardInfoPools: expected rational for \(label), got \(prim)")
    }

    private static func readInt(_ prim: Primitive, label: String) throws -> Int {
        switch prim {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardInfoPools: expected integer for \(label)")
        }
    }

    private static func readDouble(_ prim: Primitive, label: String) throws -> Double {
        switch prim {
        case .float(let d): return d
        case .uint(let u): return Double(u)
        case .int(let i): return Double(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("RewardInfoPools: expected number for \(label)")
        }
    }
}
