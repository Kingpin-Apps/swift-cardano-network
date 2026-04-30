import Foundation
import OrderedCollections
import SwiftCardanoCore

// MARK: - GovernanceState

/// The current Conway governance state.
///
/// Returned by `GetGovState` (query tag 24).
///
/// Wire format (Conway): CBOR list of 7 fields (positional, Haskell ToCBOR order):
///   [0] Proposals       — prevGovActionIds (list[4] of StrictMaybe GovActionID) + active proposals
///   [1] CommitteeState  — StrictMaybe wrapping: list[2] [cold→expiry map, hot-auth map]
///   [2] Constitution    — list[2]: [anchor, optional scriptHash]
///   [3] CurrentPParams  — 31-field positional list (n2c ProtocolParameters encoding)
///   [4] PrevPParams     — 31-field positional list
///   [5] FuturePParams   — list[1..2]: [0]=NoPParamsUpdate; [1,pp]=DefiniteUpdate; [2,pp]=PotentialUpdate
///   [6] DRepPulsingState — complex internal pulsing/ratification state (kept opaque)
public struct GovernanceState: Serializable {
    public let proposals: GovernanceProposals
    public let committeeState: GovernanceCommitteeState?
    public let constitution: Constitution
    public let currentPParams: ProtocolParameters
    public let prevPParams: ProtocolParameters
    public let futurePParams: FuturePParams
    /// DRep vote pulsing/ratification state at this epoch boundary.
    public let pulsingState: DRepPulsingState

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 7 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceState: expected list of 7+ elements")
        }

        proposals      = try GovernanceProposals(from: f[0])
        committeeState = try GovernanceCommitteeState.fromStrictMaybe(f[1])
        constitution   = try Constitution(from: f[2])
        currentPParams = try ProtocolParameters(from: f[3])
        prevPParams    = try ProtocolParameters(from: f[4])
        futurePParams  = try FuturePParams(from: f[5])
        pulsingState   = try DRepPulsingState(from: f[6])
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try proposals.toPrimitive(),
            try GovernanceCommitteeState.toStrictMaybe(committeeState),
            try constitution.toPrimitive(),
            try currentPParams.toPrimitive(),
            try prevPParams.toPrimitive(),
            try futurePParams.toPrimitive(),
            try pulsingState.toPrimitive(),
        ])
    }

    public static func == (lhs: GovernanceState, rhs: GovernanceState) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

// MARK: - GovernanceProposals

/// The active governance proposals and their previous-action anchors.
///
/// Wire: list[2]:
///   [0] PrevGovActionIds — list[4] of StrictMaybe(GovActionID)
///       ordered: PParamUpdate, HardFork, Committee, Constitution
///   [1] Active proposals — list[N] of GovernanceProposal
public struct GovernanceProposals: Serializable {
    public let prevGovActionIds: PrevGovActionIds
    public let proposals: [GovernanceProposal]

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceProposals: expected list[2], got \(primitive)")
        }
        prevGovActionIds = try PrevGovActionIds(from: f[0])
        guard case .list(let proposalList) = f[1] else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceProposals: proposals must be a list")
        }
        proposals = try proposalList.map { try GovernanceProposal(from: $0) }
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try prevGovActionIds.toPrimitive(),
            .list(try proposals.map { try $0.toPrimitive() }),
        ])
    }
}

// MARK: - PrevGovActionIds

/// The most recently enacted GovActionID for each governance action purpose.
///
/// Wire: list[4] of StrictMaybe(GovActionID)
///   [0] PParamUpdate, [1] HardFork, [2] Committee, [3] Constitution
/// StrictMaybe encoding: list[0] = Nothing (nil), list[1][x] = Just(x)
public struct PrevGovActionIds: Serializable {
    public let pParamUpdate: GovActionID?
    public let hardFork: GovActionID?
    public let committee: GovActionID?
    public let constitution: GovActionID?

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PrevGovActionIds: expected list[4], got \(primitive)")
        }
        pParamUpdate = try Self.decodeStrictMaybe(f[0])
        hardFork     = try Self.decodeStrictMaybe(f[1])
        committee    = try Self.decodeStrictMaybe(f[2])
        constitution = try Self.decodeStrictMaybe(f[3])
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try Self.encodeStrictMaybe(pParamUpdate),
            try Self.encodeStrictMaybe(hardFork),
            try Self.encodeStrictMaybe(committee),
            try Self.encodeStrictMaybe(constitution),
        ])
    }

    private static func decodeStrictMaybe(_ p: Primitive) throws -> GovActionID? {
        guard case .list(let items) = p else { return nil }
        if items.isEmpty { return nil }
        return try GovActionID(from: items[0])
    }

    private static func encodeStrictMaybe(_ id: GovActionID?) throws -> Primitive {
        guard let id else { return .list([]) }
        return .list([try id.toPrimitive()])
    }
}

// MARK: - Vote entries

/// A constitutional committee member's vote on a governance proposal.
public struct CommitteeVote: Serializable {
    public let credential: CommitteeHotCredential
    public let vote: Vote

    public init(credential: CommitteeHotCredential, vote: Vote) {
        self.credential = credential
        self.vote = vote
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CommitteeVote: expected [credential, vote]")
        }
        credential = try CommitteeHotCredential(from: f[0])
        vote       = try VoteHelpers.readVote(f[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([try credential.toPrimitive(), .uint(UInt(vote.rawValue))])
    }
}

/// A DRep's vote on a governance proposal.
public struct DRepVote: Serializable {
    public let credential: DRepCredential
    public let vote: Vote

    public init(credential: DRepCredential, vote: Vote) {
        self.credential = credential
        self.vote = vote
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "DRepVote: expected [credential, vote]")
        }
        credential = try DRepCredential(from: f[0])
        vote       = try VoteHelpers.readVote(f[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([try credential.toPrimitive(), .uint(UInt(vote.rawValue))])
    }
}

/// A stake pool's vote on a governance proposal.
public struct StakePoolVote: Serializable {
    public let poolOperator: PoolOperator
    public let vote: Vote

    public init(poolOperator: PoolOperator, vote: Vote) {
        self.poolOperator = poolOperator
        self.vote = vote
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "StakePoolVote: expected [poolOperator, vote]")
        }
        poolOperator = try PoolOperator(from: f[0])
        vote         = try VoteHelpers.readVote(f[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([try poolOperator.toPrimitive(), .uint(UInt(vote.rawValue))])
    }
}

enum VoteHelpers {
    static func readVote(_ p: Primitive) throws -> Vote {
        switch p {
        case .uint(let u):
            guard let v = Vote(rawValue: Int(u)) else {
                throw LedgerStateDecodingError.unexpectedFormat("Vote: invalid rawValue \(u)")
            }
            return v
        case .int(let i):
            guard let v = Vote(rawValue: i) else {
                throw LedgerStateDecodingError.unexpectedFormat("Vote: invalid rawValue \(i)")
            }
            return v
        default:
            throw LedgerStateDecodingError.unexpectedFormat("Vote: expected uint, got \(p)")
        }
    }
}

// MARK: - GovernanceProposal

/// A single active governance proposal with its votes and metadata.
///
/// Wire: list[7]:
///   [0] GovActionID        — list[2]: [txHash:bytes[32], govActionIndex:uint]
///   [1] committeeVotes     — orderedDict{CommitteeHotCred → Vote}
///   [2] dRepVotes          — orderedDict{DRepCred → Vote}
///   [3] stakePoolVotes     — orderedDict{poolKeyHash:bytes → Vote}
///   [4] ProposalProcedure  — list[4]: [deposit, returnAddr, govAction, anchor]
///   [5] proposedIn         — uint (epoch)
///   [6] expiresAfter       — uint (epoch)
public struct GovernanceProposal: Serializable {
    public let govActionId: GovActionID
    /// Votes cast by constitutional committee members.
    public let committeeVotes: [CommitteeVote]
    /// Votes cast by DReps.
    public let dRepVotes: [DRepVote]
    /// Votes cast by stake pool operators.
    public let stakePoolVotes: [StakePoolVote]
    public let proposalProcedure: ProposalProcedure
    public let proposedIn: UInt64
    public let expiresAfter: UInt64

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 7 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceProposal: expected list[7], got \(primitive)")
        }
        govActionId    = try GovActionID(from: f[0])
        committeeVotes = try Self.decodeMap(f[1]) { k, v in
            CommitteeVote(
                credential: try CommitteeHotCredential(from: k),
                vote: try VoteHelpers.readVote(v))
        }
        dRepVotes = try Self.decodeMap(f[2]) { k, v in
            DRepVote(
                credential: try DRepCredential(from: k),
                vote: try VoteHelpers.readVote(v))
        }
        stakePoolVotes = try Self.decodeMap(f[3]) { k, v in
            StakePoolVote(
                poolOperator: try PoolOperator(from: k),
                vote: try VoteHelpers.readVote(v))
        }
        proposalProcedure = try ProposalProcedure(from: f[4])
        proposedIn        = try Self.readUInt(f[5], label: "proposedIn")
        expiresAfter      = try Self.readUInt(f[6], label: "expiresAfter")
    }

    public func toPrimitive() throws -> Primitive {
        var committeePairs: [(Primitive, Primitive)] = []
        for v in committeeVotes {
            committeePairs.append((try v.credential.toPrimitive(), .uint(UInt(v.vote.rawValue))))
        }
        var dRepPairs: [(Primitive, Primitive)] = []
        for v in dRepVotes {
            dRepPairs.append((try v.credential.toPrimitive(), .uint(UInt(v.vote.rawValue))))
        }
        var spoPairs: [(Primitive, Primitive)] = []
        for v in stakePoolVotes {
            spoPairs.append((try v.poolOperator.toPrimitive(), .uint(UInt(v.vote.rawValue))))
        }
        return .list([
            try govActionId.toPrimitive(),
            .dict(Dictionary(uniqueKeysWithValues: committeePairs)),
            .dict(Dictionary(uniqueKeysWithValues: dRepPairs)),
            .dict(Dictionary(uniqueKeysWithValues: spoPairs)),
            try proposalProcedure.toPrimitive(),
            .uint(UInt(proposedIn)),
            .uint(UInt(expiresAfter)),
        ])
    }

    private static func decodeMap<T>(
        _ p: Primitive,
        _ build: (Primitive, Primitive) throws -> T
    ) throws -> [T] {
        let pairs: [(Primitive, Primitive)]
        switch p {
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .dict(let d):        pairs = d.map { ($0.key, $0.value) }
        default:                  pairs = []
        }
        return try pairs.map { try build($0.0, $0.1) }
    }

    private static func readUInt(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceProposal: expected uint for \(label)")
        }
    }
}

// MARK: - CommitteeMemberEntry

/// A registered constitutional committee member: their cold credential and the
/// epoch at which their term expires. Shared by `GovernanceCommitteeState` and
/// `EnactCommittee`.
public struct CommitteeMemberEntry: Serializable {
    public let coldCred: CommitteeColdCredential
    public let expiryEpoch: UInt64

    public init(coldCred: CommitteeColdCredential, expiryEpoch: UInt64) {
        self.coldCred = coldCred
        self.expiryEpoch = expiryEpoch
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CommitteeMemberEntry: expected [coldCred, expiryEpoch]")
        }
        coldCred = try CommitteeColdCredential(from: f[0])
        switch f[1] {
        case .uint(let u):              expiryEpoch = UInt64(u)
        case .int(let i) where i >= 0:  expiryEpoch = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "CommitteeMemberEntry: expected uint expiryEpoch")
        }
    }

    public func toPrimitive() throws -> Primitive {
        .list([try coldCred.toPrimitive(), .uint(UInt(expiryEpoch))])
    }
}

// MARK: - GovernanceCommitteeState

/// The constitutional committee membership state.
///
/// Wire: StrictMaybe wrapping list[2]:
///   [0] orderedDict{ CommitteeColdCred → expiryEpoch:uint }
///   [1] threshold: UnitInterval — quorum fraction required for committee votes
public struct GovernanceCommitteeState: Serializable {
    /// Committee cold credentials and their term expiry epochs.
    public let members: [CommitteeMemberEntry]
    /// Quorum threshold required for committee votes to count.
    public let threshold: UnitInterval

    public init(members: [CommitteeMemberEntry], threshold: UnitInterval) {
        self.members = members
        self.threshold = threshold
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceCommitteeState: expected list[2], got \(primitive)")
        }
        let pairs = Self.dictPairs(f[0])
        members = try pairs.map { (k, v) in
            let cred = try CommitteeColdCredential(from: k)
            let epoch: UInt64
            switch v {
            case .uint(let u): epoch = UInt64(u)
            case .int(let i) where i >= 0: epoch = UInt64(i)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "GovernanceCommitteeState: expected uint expiry, got \(v)")
            }
            return CommitteeMemberEntry(coldCred: cred, expiryEpoch: epoch)
        }
        threshold = try UnitInterval(from: f[1])
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for m in members {
            pairs.append((try m.coldCred.toPrimitive(), .uint(UInt(m.expiryEpoch))))
        }
        return .list([
            .dict(Dictionary(uniqueKeysWithValues: pairs)),
            try threshold.toPrimitive(),
        ])
    }

    static func fromStrictMaybe(_ p: Primitive) throws -> GovernanceCommitteeState? {
        guard case .list(let items) = p else { return nil }
        if items.isEmpty { return nil }
        return try GovernanceCommitteeState(from: items[0])
    }

    static func toStrictMaybe(_ state: GovernanceCommitteeState?) throws -> Primitive {
        guard let state else { return .list([]) }
        return .list([try state.toPrimitive()])
    }

    private static func dictPairs(_ p: Primitive) -> [(Primitive, Primitive)] {
        switch p {
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .dict(let d): return d.map { ($0.key, $0.value) }
        default: return []
        }
    }
}

// MARK: - PulsingSnapshot

/// Snapshot of the in-progress DRep ratification computation, captured each
/// time the pulser runs. Exposes the proposals being considered along with the
/// stake distributions used to weight DRep votes and pool voting.
///
/// Wire format: a 4-element CBOR list:
/// ```
/// [proposals, drepStakeDistr, drepStates, poolStakeDistr]
/// ```
///   - `proposals`:        list of `GovActionState` (= our `GovernanceProposal`).
///   - `drepStakeDistr`:   `{ DRep credential → coin }` — DRep delegated stake.
///   - `drepStates`:       `{ DRep credential → DRepStateEntry payload }` — registration state.
///   - `poolStakeDistr`:   `{ pool key hash → coin }` — pool delegated stake.
public struct PulsingSnapshot: Serializable {
    /// Currently active governance proposals being ratified this epoch.
    public let proposals: [GovernanceProposal]
    /// DRep credential → total delegated stake (lovelace).
    public let drepStakeDistribution: [DRepStakeEntry]
    /// DRep credential → registration state (deposit, expiry, anchor).
    public let drepStates: [DRepStateEntry]
    /// Stake-pool key hash → total delegated stake (lovelace).
    public let poolStakeDistribution: [SPOStakeEntry]

    public init(
        proposals: [GovernanceProposal] = [],
        drepStakeDistribution: [DRepStakeEntry] = [],
        drepStates: [DRepStateEntry] = [],
        poolStakeDistribution: [SPOStakeEntry] = []
    ) {
        self.proposals = proposals
        self.drepStakeDistribution = drepStakeDistribution
        self.drepStates = drepStates
        self.poolStakeDistribution = poolStakeDistribution
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PulsingSnapshot: expected [proposals, drepDistr, drepStates, poolDistr]")
        }
        guard case .list(let propList) = f[0] else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PulsingSnapshot: proposals must be a list")
        }
        proposals             = try propList.map { try GovernanceProposal(from: $0) }
        drepStakeDistribution = try DRepStakeDistribution(from: f[1]).entries
        drepStates            = try DRepState(from: f[2]).entries
        poolStakeDistribution = try SPOStakeDistribution(from: f[3]).entries
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            .list(try proposals.map { try $0.toPrimitive() }),
            try DRepStakeDistribution(entries: drepStakeDistribution).toPrimitive(),
            try DRepState(entries: drepStates).toPrimitive(),
            try SPOStakeDistribution(entries: poolStakeDistribution).toPrimitive(),
        ])
    }
}

// MARK: - DRepPulsingState

/// The DRep ratification computation at this epoch boundary.
///
/// The pulser runs incrementally throughout the epoch and exposes a
/// `PulsingSnapshot` (proposals + stake distributions) along with the
/// `RatifyState` the ledger uses for ratification:
///
/// - `.pulsing` — mid-epoch; the pulser hasn't finished yet, but the snapshot
///   and provisional ratify-state are observable.
/// - `.complete` — epoch boundary reached; ratification is finalised.
///   `snapshot` is empty (the wire form drops it for `complete`).
///
/// Wire format (no outer tag — variants are distinguished by shape):
///   - DRPulsing  → 2-element list `[pulsingSnapshot, ratifyState]`
///   - DRComplete → bare 4-element `RatifyState` `[enactState, enacted, expired, delayed]`
public enum DRepPulsingState: Serializable {
    /// Mid-epoch in-progress ratification computation.
    case pulsing(snapshot: PulsingSnapshot, ratifyState: RatifyState)
    /// Epoch-boundary completed ratification state. `snapshot` is empty —
    /// the wire form drops it once ratification has been finalised.
    case complete(snapshot: PulsingSnapshot, ratifyState: RatifyState)

    /// Snapshot accessor — empty for `.complete`.
    public var snapshot: PulsingSnapshot {
        switch self {
        case .pulsing(let s, _), .complete(let s, _): return s
        }
    }

    /// Ratify-state accessor — same shape regardless of variant.
    public var ratifyState: RatifyState {
        switch self {
        case .pulsing(_, let r), .complete(_, let r): return r
        }
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "DRepPulsingState: expected list, got \(primitive)")
        }

        // DRComplete: bare 4-element RatifyState (last field is bool).
        if f.count == 4, case .bool = f[3] {
            let rs = try RatifyState(from: primitive)
            self = .complete(snapshot: PulsingSnapshot(), ratifyState: rs)
            return
        }

        // DRPulsing: [pulsingSnapshot, ratifyState].
        if f.count == 2 {
            let snap = try PulsingSnapshot(from: f[0])
            let rs   = try RatifyState(from: f[1])
            self = .pulsing(snapshot: snap, ratifyState: rs)
            return
        }

        throw LedgerStateDecodingError.unexpectedFormat(
            "DRepPulsingState: unrecognised wire layout (count=\(f.count))")
    }

    public func toPrimitive() throws -> Primitive {
        switch self {
        case .pulsing(let snap, let rs):
            return .list([try snap.toPrimitive(), try rs.toPrimitive()])
        case .complete(_, let rs):
            // Wire form drops the snapshot once ratification is complete.
            return try rs.toPrimitive()
        }
    }

    /// Labeled JSON. The default Mirror-based `toDict` can't reflect the
    /// labelled-tuple associated value, so emit it explicitly.
    public func toDict() throws -> Primitive {
        var inner = OrderedDictionary<Primitive, Primitive>()
        inner[.string("snapshot")]    = try snapshot.toDict()
        inner[.string("ratifyState")] = try ratifyState.toDict()
        var outer = OrderedDictionary<Primitive, Primitive>()
        switch self {
        case .pulsing:  outer[.string("pulsing")]  = .orderedDict(inner)
        case .complete: outer[.string("complete")] = .orderedDict(inner)
        }
        return .orderedDict(outer)
    }
}

extension DRepPulsingState: Equatable {
    public static func == (lhs: DRepPulsingState, rhs: DRepPulsingState) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
}

extension DRepPulsingState: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

// MARK: - FuturePParams

/// The future protocol parameters update status.
///
/// Wire (Conway): list[1..2] where the second element, when present, is a
/// `Maybe ProtocolParameters` encoded as a Haskell list (`[]` for Nothing,
/// `[params]` for Just).  In practice the node has been observed to emit:
///
///   [0]              uint(0)   = NoPParamsUpdate
///   [1, []]                    = DefiniteUpdate Nothing
///   [1, [params]]              = DefiniteUpdate (Just params)
///   [2, []]                    = PotentialUpdate Nothing
///   [2, [params]]              = PotentialUpdate (Just params)
///
/// `params` is the n2c 31-element positional `ProtocolParameters` array.
public enum FuturePParams: Serializable {
    case noUpdate
    case definiteUpdate(ProtocolParameters?)
    case potentialUpdate(ProtocolParameters?)

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, !f.isEmpty else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "FuturePParams: expected non-empty list, got \(primitive)")
        }
        let tag: UInt
        switch f[0] {
        case .uint(let u): tag = u
        case .int(let i) where i >= 0: tag = UInt(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "FuturePParams: expected uint tag, got \(f[0])")
        }
        switch tag {
        case 0:
            self = .noUpdate
        case 1:
            self = .definiteUpdate(try Self.decodeMaybeParams(f, label: "definiteUpdate"))
        case 2:
            self = .potentialUpdate(try Self.decodeMaybeParams(f, label: "potentialUpdate"))
        default:
            throw LedgerStateDecodingError.unexpectedFormat("FuturePParams: unknown tag \(tag)")
        }
    }

    /// Decodes the Haskell-style `Maybe ProtocolParameters` that sits at
    /// index 1 of the outer list — accepting either:
    /// - the wrapped form `[]` (Nothing) / `[<31-element pparams list>]` (Just), or
    /// - the unwrapped form where the params list itself is at index 1
    ///   (older node encodings observed in the wild).
    private static func decodeMaybeParams(
        _ f: [Primitive], label: String
    ) throws -> ProtocolParameters? {
        guard f.count >= 2 else { return nil }
        guard case .list(let inner) = f[1] else {
            // Fallback: treat any non-list f[1] as a direct params primitive.
            return try ProtocolParameters(from: f[1])
        }
        if inner.isEmpty { return nil }
        // Heuristic: the node emits `[<31-element pparams list>]` when the
        // wrapper is `Just`, but earlier encodings put the 31-element pparams
        // list directly at f[1].  The 31-element pparams list also contains
        // exactly 31 elements at the top level — distinguish by looking at
        // inner.count.
        if inner.count == 1, case .list = inner[0] {
            return try ProtocolParameters(from: inner[0])
        }
        return try ProtocolParameters(from: f[1])
    }

    public func toPrimitive() throws -> Primitive {
        switch self {
        case .noUpdate:
            return .list([.uint(0)])
        case .definiteUpdate(let pp):
            return .list([.uint(1), try Self.encodeMaybeParams(pp)])
        case .potentialUpdate(let pp):
            return .list([.uint(2), try Self.encodeMaybeParams(pp)])
        }
    }

    private static func encodeMaybeParams(_ pp: ProtocolParameters?) throws -> Primitive {
        guard let pp else { return .list([]) }
        return .list([try pp.toPrimitive()])
    }
}

// MARK: - Equatable & Hashable (via toPrimitive round-trip)

extension GovernanceProposals {
    public static func == (lhs: GovernanceProposals, rhs: GovernanceProposals) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

extension PrevGovActionIds {
    public static func == (lhs: PrevGovActionIds, rhs: PrevGovActionIds) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

extension GovernanceProposal {
    public static func == (lhs: GovernanceProposal, rhs: GovernanceProposal) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

extension GovernanceCommitteeState {
    public static func == (lhs: GovernanceCommitteeState, rhs: GovernanceCommitteeState) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}
