import Foundation
import OrderedCollections
import SwiftCardanoCore

// MARK: - StakePointer

/// A stake address pointer: a compact alternative to a full stake credential reference.
///
/// Wire format: a 3-element CBOR list `[slotNo, txIndex, certIndex]`.
public struct StakePointer: Sendable, Equatable, Hashable {
    public let slotNo: UInt64
    public let txIndex: UInt64
    public let certIndex: UInt64

    public init(slotNo: UInt64, txIndex: UInt64, certIndex: UInt64) {
        self.slotNo = slotNo
        self.txIndex = txIndex
        self.certIndex = certIndex
    }

    static func from(_ primitive: Primitive) throws -> StakePointer {
        guard case .list(let f) = primitive, f.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "StakePointer: expected [slotNo, txIndex, certIndex]")
        }
        return StakePointer(
            slotNo: try uint(f[0], label: "slotNo"),
            txIndex: try uint(f[1], label: "txIndex"),
            certIndex: try uint(f[2], label: "certIndex")
        )
    }

    func toPrimitive() -> Primitive {
        .list([.uint(UInt64(slotNo)), .uint(UInt64(txIndex)), .uint(UInt64(certIndex))])
    }

    private static func uint(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakePointer: \(label) must be uint")
        }
    }
}

// MARK: - UMapEntry

/// A single entry in the Conway unified stake map (UMap).
///
/// Wire format: a 4-element CBOR list per entry value, with `null` for absent fields:
/// ```
/// [StrictMaybe(reward), StrictMaybe(deposit), StrictMaybe(poolKeyHash), StrictMaybe(drep)]
/// ```
///
/// - `reward`:      `null` if no rewards accumulated yet, else `uint(lovelace)`.
/// - `deposit`:     `null` if no deposit held (shouldn't happen post-registration), else `uint`.
/// - `poolKeyHash`: `null` if not delegating, else `bytes(28)`.
/// - `drep`:        `null` if no vote delegation, else DRep-encoded list (e.g. `[2]` for abstain).
public struct UMapEntry: Serializable {
    /// The stake credential this entry belongs to.
    public let credential: StakeCredential
    /// Accumulated reward balance in lovelace (`umeCoin`); 0 if none.
    public let reward: UInt64
    /// Stake key registration deposit in lovelace (`umeDeposit`); 0 if none.
    public let deposit: UInt64
    /// Pool this credential delegates to (`umeSPool`); `nil` if undelegated.
    public let poolOperator: PoolOperator?
    /// DRep this credential delegates votes to (`umeDRep`); `nil` if not set.
    public let drep: DRep?

    public init(
        credential: StakeCredential,
        reward: UInt64,
        deposit: UInt64,
        poolOperator: PoolOperator?,
        drep: DRep?
    ) {
        self.credential = credential
        self.reward = reward
        self.deposit = deposit
        self.poolOperator = poolOperator
        self.drep = drep
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 5 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "UMapEntry: expected [credential, reward, deposit, poolOperator?, drep?]")
        }
        credential = try StakeCredential(from: f[0])
        switch f[1] {
        case .uint(let u):              reward = UInt64(u)
        case .int(let i) where i >= 0:  reward = UInt64(i)
        default:                        reward = 0
        }
        switch f[2] {
        case .uint(let u):              deposit = UInt64(u)
        case .int(let i) where i >= 0:  deposit = UInt64(i)
        default:                        deposit = 0
        }
        poolOperator = (f[3] == .null) ? nil : (try? PoolOperator(from: f[3]))
        drep         = (f[4] == .null) ? nil : (try? DRep(from: f[4]))
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try credential.toPrimitive(),
            .uint(UInt64(reward)),
            .uint(UInt64(deposit)),
            (try poolOperator?.toPrimitive()) ?? .null,
            (try drep?.toPrimitive()) ?? .null,
        ])
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("credential")]   = try credential.toPrimitive()
        dict[.string("reward")]       = .uint(UInt64(reward))
        dict[.string("deposit")]      = .uint(UInt64(deposit))
        dict[.string("poolOperator")] = try poolOperator.map { try $0.toDict() } ?? .null
        dict[.string("drep")]         = try drep?.toPrimitive() ?? .null
        return .orderedDict(dict)
    }

    public static func == (lhs: UMapEntry, rhs: UMapEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && lhs.reward == rhs.reward
            && lhs.deposit == rhs.deposit
            && lhs.poolOperator == rhs.poolOperator
            && (try? lhs.drep?.toPrimitive()) == (try? rhs.drep?.toPrimitive())
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        reward.hash(into: &hasher)
        deposit.hash(into: &hasher)
    }
}

// MARK: - DState

/// Delegation state for stake credentials in the Conway era.
///
/// Wire format: a 4-element CBOR list `[umap, futureGenDelegs, genDelegs, iRewards]`.
///
/// - `umap`: `[elemMap, ptrMap]` — the unified stake/reward/delegation map.
///   - `elemMap`: `{ StakeCredential → [null|Coin, null|Coin, null|bytes28, null|DRep] }`
///   - `ptrMap`: `{ StakePointer → StakeCredential }` — always empty in Conway.
/// - `futureGenDelegs`, `genDelegs`, `iRewards`: legacy genesis/MIR fields — always empty
///   in Conway; kept opaque.
public struct DState: Serializable {

    /// All registered stake credentials and their associated reward/delegation state.
    public let accounts: [UMapEntry]

    /// Stake pointer → credential map (legacy; always empty in Conway).
    public let stakePointers: [(StakePointer, StakeCredential)]

    // Legacy fields, always empty in Conway.
    public let rawFutureGenDelegs: Primitive
    public let rawGenDelegs: Primitive
    public let rawInstantaneousRewards: Primitive

    public init(
        accounts: [UMapEntry] = [],
        stakePointers: [(StakePointer, StakeCredential)] = [],
        rawFutureGenDelegs: Primitive = .dict([:]),
        rawGenDelegs: Primitive = .dict([:]),
        rawInstantaneousRewards: Primitive = .list([.dict([:]), .dict([:]), .uint(0), .uint(0)])
    ) {
        self.accounts = accounts
        self.stakePointers = stakePointers
        self.rawFutureGenDelegs = rawFutureGenDelegs
        self.rawGenDelegs = rawGenDelegs
        self.rawInstantaneousRewards = rawInstantaneousRewards
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "DState: expected [umap, futureGenDelegs, genDelegs, iRewards]")
        }
        rawFutureGenDelegs      = f[1]
        rawGenDelegs            = f[2]
        rawInstantaneousRewards = f[3]

        // UMap = [elemMap, ptrMap]
        guard case .list(let um) = f[0], um.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "DState: UMap must be [elemMap, ptrMap]")
        }
        accounts      = try Self.parseElemMap(um[0])
        stakePointers = try Self.parsePtrMap(um[1])
    }

    public func toPrimitive() throws -> Primitive {
        var elemPairs: [(Primitive, Primitive)] = []
        for entry in accounts {
            let key = try entry.credential.toPrimitive()
            let value = Primitive.list([
                entry.reward > 0 ? .uint(UInt64(entry.reward)) : .null,
                entry.deposit > 0 ? .uint(UInt64(entry.deposit)) : .null,
                (try entry.poolOperator?.toPrimitive()) ?? .null,
                (try? entry.drep?.toPrimitive()) ?? .null,
            ])
            elemPairs.append((key, value))
        }
        var ptrPairs: [(Primitive, Primitive)] = []
        for (ptr, cred) in stakePointers {
            ptrPairs.append((ptr.toPrimitive(), try cred.toPrimitive()))
        }
        let umap = Primitive.list([
            .frozenDict(Dictionary(uniqueKeysWithValues: elemPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: ptrPairs)),
        ])
        return .list([umap, rawFutureGenDelegs, rawGenDelegs, rawInstantaneousRewards])
    }

    // MARK: - Private helpers

    private static func parseElemMap(_ primitive: Primitive) throws -> [UMapEntry] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DState: elemMap must be a CBOR map")
        }
        return try pairs.map { (key, value) in
            let credential = try StakeCredential(from: key)
            guard case .list(let elems) = value, elems.count >= 4 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "DState: UMElem must be [reward, deposit, spool, drep]")
            }
            let reward: UInt64 = Self.nullableUInt(elems[0]) ?? 0
            let deposit: UInt64 = Self.nullableUInt(elems[1]) ?? 0
            let poolOperator: PoolOperator? = (elems[2] == .null) ? nil : (try? PoolOperator(from: elems[2]))
            let drep: DRep? = elems[3] == .null ? nil : (try? DRep(from: elems[3]))
            return UMapEntry(
                credential: credential,
                reward: reward,
                deposit: deposit,
                poolOperator: poolOperator,
                drep: drep
            )
        }
    }

    private static func parsePtrMap(
        _ primitive: Primitive
    ) throws -> [(StakePointer, StakeCredential)] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DState: ptrMap must be a CBOR map")
        }
        return try pairs.map { (key, value) in
            let ptr = try StakePointer.from(key)
            let cred = try StakeCredential(from: value)
            return (ptr, cred)
        }
    }

    private static func nullableUInt(_ p: Primitive) -> UInt64? {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        case .null: return nil
        default: return nil
        }
    }

    private static func nullableBytes(_ p: Primitive) -> Data? {
        switch p {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        case .null: return nil
        default: return nil
        }
    }
}

extension DState: Equatable {
    public static func == (lhs: DState, rhs: DState) -> Bool {
        lhs.accounts == rhs.accounts
    }
}

extension DState: Hashable {
    public func hash(into hasher: inout Hasher) {
        accounts.count.hash(into: &hasher)
    }
}

// MARK: - PState

/// Stake pool registration state.
///
/// Wire format: a 4- or 5-element CBOR list:
/// ```
/// [stakePools, futureStakePools, retiring, deposits, vrfKeyHashes?]
/// ```
///
/// - `stakePools`:      `{ poolKeyHash → PoolParams }` — currently registered pools.
/// - `futureStakePools`: `{ poolKeyHash → PoolParams }` — pending parameter updates.
/// - `retiring`:        `{ poolKeyHash → epochNo }` — pools with filed retirement.
/// - `deposits`:        `{ poolKeyHash → coin }` — pool registration deposits.
/// - `vrfKeyHashes`:    `{ poolKeyHash → bytes(32) }` — VRF key hashes (Conway+, optional).
public struct PState: Serializable {

    /// Currently registered pool parameters.
    public let stakePools: [PoolOperator: PoolParams]
    /// Pending pool parameter updates for the next epoch.
    public let futureStakePools: [PoolOperator: PoolParams]
    /// Pools with pending retirement and their retirement epoch.
    public let retiring: [PoolOperator: UInt64]
    /// Pool registration deposit per pool.
    public let deposits: [PoolOperator: UInt64]
    /// VRF verification key hashes per pool (Conway+).
    public let vrfKeyHashes: [PoolOperator: VrfKeyHash]

    public init(
        stakePools: [PoolOperator: PoolParams] = [:],
        futureStakePools: [PoolOperator: PoolParams] = [:],
        retiring: [PoolOperator: UInt64] = [:],
        deposits: [PoolOperator: UInt64] = [:],
        vrfKeyHashes: [PoolOperator: VrfKeyHash] = [:]
    ) {
        self.stakePools = stakePools
        self.futureStakePools = futureStakePools
        self.retiring = retiring
        self.deposits = deposits
        self.vrfKeyHashes = vrfKeyHashes
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PState: expected [stakePools, futureStakePools, retiring, deposits, vrfKeyHashes?]")
        }
        stakePools      = try Self.parsePoolParamsMap(f[0], label: "stakePools")
        futureStakePools = try Self.parsePoolParamsMap(f[1], label: "futureStakePools")
        retiring        = try Self.parseUIntMap(f[2], label: "retiring")
        deposits        = try Self.parseUIntMap(f[3], label: "deposits")
        vrfKeyHashes    = f.count > 4 ? (try Self.parseVrfMap(f[4], label: "vrfKeyHashes")) : [:]
    }

    public func toPrimitive() throws -> Primitive {
        let spPairs: [(Primitive, Primitive)] = try stakePools.map { (k, v) in
            (try k.toPrimitive(), try v.toPrimitive())
        }
        let fspPairs: [(Primitive, Primitive)] = try futureStakePools.map { (k, v) in
            (try k.toPrimitive(), try v.toPrimitive())
        }
        let retPairs: [(Primitive, Primitive)] = try retiring.map {
            (try $0.toPrimitive(), .uint(UInt64($1)))
        }
        let depPairs: [(Primitive, Primitive)] = try deposits.map {
            (try $0.toPrimitive(), .uint(UInt64($1)))
        }
        let vrfPairs: [(Primitive, Primitive)] = try vrfKeyHashes.map {
            (try $0.toPrimitive(), $1.toPrimitive())
        }
        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: spPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: fspPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: retPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: depPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: vrfPairs)),
        ])
    }

    /// Render dicts keyed by `PoolOperator` as `{ bech32-pool-id: value }` JSON
    /// objects rather than raw byte keys.
    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("stakePools")]       = try Self.poolDict(stakePools)       { try $0.toPrimitive() }
        dict[.string("futureStakePools")] = try Self.poolDict(futureStakePools) { try $0.toPrimitive() }
        dict[.string("retiring")]         = try Self.poolDict(retiring)         { .uint(UInt64($0)) }
        dict[.string("deposits")]         = try Self.poolDict(deposits)         { .uint(UInt64($0)) }
        dict[.string("vrfKeyHashes")]     = try Self.poolDict(vrfKeyHashes)     { try $0.toDict() }
        return .orderedDict(dict)
    }

    private static func poolDict<V>(
        _ map: [PoolOperator: V],
        encode: (V) throws -> Primitive
    ) throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for (k, v) in map {
            pairs.append((.string(try k.toBech32()), try encode(v)))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    private static func parsePoolParamsMap(
        _ primitive: Primitive, label: String
    ) throws -> [PoolOperator: PoolParams] {
        var out: [PoolOperator: PoolParams] = [:]
        for (k, v) in try mapPairs(primitive, label: label) {
            out[try PoolOperator(from: k)] = try PoolParams(from: v)
        }
        return out
    }

    private static func parseUIntMap(
        _ primitive: Primitive, label: String
    ) throws -> [PoolOperator: UInt64] {
        var out: [PoolOperator: UInt64] = [:]
        for (k, v) in try mapPairs(primitive, label: label) {
            out[try PoolOperator(from: k)] = try uintValue(v, label: label)
        }
        return out
    }

    private static func parseVrfMap(
        _ primitive: Primitive, label: String
    ) throws -> [PoolOperator: VrfKeyHash] {
        var out: [PoolOperator: VrfKeyHash] = [:]
        for (k, v) in try mapPairs(primitive, label: label) {
            out[try PoolOperator(from: k)] = try VrfKeyHash(from: v)
        }
        return out
    }

    private static func mapPairs(_ p: Primitive, label: String) throws -> [(Primitive, Primitive)] {
        switch p {
        case .dict(let d):        return Array(d)
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  return Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PState: expected map for \(label)")
        }
    }

    private static func uintValue(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "PState: expected uint in \(label)")
        }
    }
}

extension PState: Equatable {
    public static func == (lhs: PState, rhs: PState) -> Bool {
        lhs.retiring == rhs.retiring && lhs.deposits == rhs.deposits
    }
}

extension PState: Hashable {
    public func hash(into hasher: inout Hasher) {
        stakePools.count.hash(into: &hasher)
    }
}

// MARK: - CommitteeAuthorization

/// The authorization status of a committee cold credential.
///
/// Wire format: a 2-element CBOR list `[tag, value]`:
/// - `[0, hot_credential]` = `HotCredential` — the cold key has authorized this hot key.
/// - `[1, anchor_or_null]` = `Resigned` — the member resigned (with optional anchor).
public enum CommitteeAuthorization: Sendable {
    /// Hot credential that has been authorized by this cold key.
    case hotCredential(CommitteeHotCredential)
    /// Member has resigned; optional anchor provides a statement URL.
    case resigned(LedgerAnchor?)
}

extension CommitteeAuthorization: Equatable {
    public static func == (lhs: CommitteeAuthorization, rhs: CommitteeAuthorization) -> Bool {
        switch (lhs, rhs) {
        case (.resigned(let la), .resigned(let ra)): return la == ra
        case (.hotCredential(let lc), .hotCredential(let rc)):
            return (try? lc.toPrimitive()) == (try? rc.toPrimitive())
        default: return false
        }
    }
}

extension CommitteeAuthorization: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .resigned: hasher.combine(1)
        case .hotCredential(let c):
            hasher.combine(0)
            if let p = try? c.toPrimitive() { p.hash(into: &hasher) }
        }
    }
}

// MARK: - CommitteeStateEntry

/// A single entry in the committee authorization map.
public struct CommitteeStateEntry: Sendable {
    /// The cold credential identifying this committee member.
    public let coldCredential: CommitteeColdCredential
    /// Whether the member has authorized a hot key or resigned.
    public let authorization: CommitteeAuthorization

    public init(coldCredential: CommitteeColdCredential, authorization: CommitteeAuthorization) {
        self.coldCredential = coldCredential
        self.authorization = authorization
    }
}

extension CommitteeStateEntry: Equatable {
    public static func == (lhs: CommitteeStateEntry, rhs: CommitteeStateEntry) -> Bool {
        (try? lhs.coldCredential.toPrimitive()) == (try? rhs.coldCredential.toPrimitive())
            && lhs.authorization == rhs.authorization
    }
}

extension CommitteeStateEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? coldCredential.toPrimitive() { p.hash(into: &hasher) }
    }
}

// MARK: - VState

/// Voting / governance state for the Conway era.
///
/// Wire format: a 3-element CBOR list `[drepsMap, committeeState, numDormantEpochs]`.
///
/// - `drepsMap`: `{ DRepCredential → [expiry, anchor?, deposit] }` — same encoding as
///   `GetDRepState` query.
/// - `committeeState`: `{ CommitteeColdCredential → [0, hot_cred] | [1, anchor?] }`.
/// - `numDormantEpochs`: `UInt64` — epochs without an enacted governance proposal.
public struct VState: Serializable {

    /// Registered DReps and their current on-chain state.
    public let dreps: [DRepStateEntry]
    /// Committee cold credential → authorization (hot key or resigned).
    public let committeeAuths: [CommitteeStateEntry]
    /// Number of consecutive epochs with no enacted governance action.
    public let numDormantEpochs: UInt64

    public init(
        dreps: [DRepStateEntry] = [],
        committeeAuths: [CommitteeStateEntry] = [],
        numDormantEpochs: UInt64 = 0
    ) {
        self.dreps = dreps
        self.committeeAuths = committeeAuths
        self.numDormantEpochs = numDormantEpochs
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "VState: expected [drepsMap, committeeState, numDormantEpochs]")
        }
        dreps = try DRepState(from: f[0]).entries
        committeeAuths = try Self.parseCommitteeState(f[1])
        numDormantEpochs = try Self.uint(f[2], label: "numDormantEpochs")
    }

    public func toPrimitive() throws -> Primitive {
        let drepState = DRepState(entries: dreps)
        let drepMap = try drepState.toPrimitive()

        var committeePairs: [(Primitive, Primitive)] = []
        for entry in committeeAuths {
            let key = try entry.coldCredential.toPrimitive()
            let value: Primitive
            switch entry.authorization {
            case .hotCredential(let cred):
                value = .list([.uint(0), try cred.toPrimitive()])
            case .resigned(let anchor):
                if let a = anchor {
                    value = .list([.uint(1), .list([.string(a.url), .bytes(a.dataHash)])])
                } else {
                    value = .list([.uint(1), .null])
                }
            }
            committeePairs.append((key, value))
        }
        return .list([
            drepMap,
            .frozenDict(Dictionary(uniqueKeysWithValues: committeePairs)),
            .uint(UInt64(numDormantEpochs)),
        ])
    }

    private static func parseCommitteeState(
        _ primitive: Primitive
    ) throws -> [CommitteeStateEntry] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "VState: committeeState must be a CBOR map")
        }
        return try pairs.map { (key, value) in
            let coldCred = try CommitteeColdCredential(from: key)
            guard case .list(let elems) = value, elems.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "VState: CommitteeAuthorization must be [tag, value]")
            }
            let tag = try Self.uint(elems[0], label: "CommitteeAuthorization tag")
            let auth: CommitteeAuthorization
            switch tag {
            case 0:
                let hotCred = try CommitteeHotCredential(from: elems[1])
                auth = .hotCredential(hotCred)
            case 1:
                let anchor: LedgerAnchor? = try Self.parseAnchorOrNull(elems[1])
                auth = .resigned(anchor)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "VState: unknown CommitteeAuthorization tag \(tag)")
            }
            return CommitteeStateEntry(coldCredential: coldCred, authorization: auth)
        }
    }

    private static func parseAnchorOrNull(_ p: Primitive) throws -> LedgerAnchor? {
        switch p {
        case .null: return nil
        case .list(let elems) where elems.isEmpty: return nil
        case .list(let elems) where elems.count >= 2:
            let url: String
            switch elems[0] {
            case .string(let s): url = s
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "VState: anchor URL must be a string")
            }
            let dataHash: Data
            switch elems[1] {
            case .bytes(let d): dataHash = d
            case .byteArray(let b): dataHash = Data(b)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "VState: anchor hash must be bytes")
            }
            return LedgerAnchor(url: url, dataHash: dataHash)
        default:
            return nil
        }
    }

    private static func uint(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "VState: expected uint for \(label), got \(p)")
        }
    }
}

extension VState: Equatable {
    public static func == (lhs: VState, rhs: VState) -> Bool {
        lhs.dreps == rhs.dreps
            && lhs.committeeAuths == rhs.committeeAuths
            && lhs.numDormantEpochs == rhs.numDormantEpochs
    }
}

extension VState: Hashable {
    public func hash(into hasher: inout Hasher) {
        dreps.count.hash(into: &hasher)
        numDormantEpochs.hash(into: &hasher)
    }
}

// MARK: - CertState

/// Certificate / delegation state for the Conway era.
///
/// Contains the full `DState` (stake credential accounts), `PState` (pool registrations),
/// and `VState` (governance/DRep/committee state).
///
/// Wire format: a 3-element CBOR list `[DState, PState, VState]`.
public struct CertState: Serializable {

    /// Stake credential accounts, rewards, and delegations (unified map).
    public let dstate: DState
    /// Registered stake pool parameters and retirement schedules.
    public let pstate: PState
    /// DRep registrations and committee authorizations.
    public let vstate: VState

    public init(dstate: DState = DState(), pstate: PState = PState(), vstate: VState = VState()) {
        self.dstate = dstate
        self.pstate = pstate
        self.vstate = vstate
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CertState: expected [DState, PState, VState]")
        }
        dstate = try DState(from: f[0])
        pstate = try PState(from: f[1])
        vstate = try VState(from: f[2])
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try dstate.toPrimitive(),
            try pstate.toPrimitive(),
            try vstate.toPrimitive(),
        ])
    }
}

extension CertState: Equatable {
    public static func == (lhs: CertState, rhs: CertState) -> Bool {
        lhs.dstate == rhs.dstate && lhs.pstate == rhs.pstate && lhs.vstate == rhs.vstate
    }
}

extension CertState: Hashable {
    public func hash(into hasher: inout Hasher) {
        dstate.hash(into: &hasher)
        pstate.hash(into: &hasher)
        vstate.hash(into: &hasher)
    }
}
