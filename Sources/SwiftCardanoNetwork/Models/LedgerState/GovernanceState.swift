import Foundation
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
public struct GovernanceState: CBORSerializable, Sendable {
    public let proposals: GovernanceProposals
    public let committeeState: GovernanceCommitteeState?
    public let constitution: Constitution
    public let currentPParams: ProtocolParameters
    public let prevPParams: ProtocolParameters
    public let futurePParams: FuturePParams
    /// Raw DRepPulsingState CBOR — complex internal ledger state kept opaque.
    public let pulsingState: Primitive

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 7 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceState: expected list of 7+ elements")
        }

        proposals     = try GovernanceProposals(from: f[0])
        committeeState = try GovernanceCommitteeState.fromStrictMaybe(f[1])
        constitution  = try Constitution(from: f[2])
        currentPParams = try ProtocolParameters(from: f[3])
        prevPParams   = try ProtocolParameters(from: f[4])
        futurePParams = try FuturePParams(from: f[5])
        pulsingState  = f[6]
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try proposals.toPrimitive(),
            try GovernanceCommitteeState.toStrictMaybe(committeeState),
            try constitution.toPrimitive(),
            try currentPParams.toPrimitive(),
            try prevPParams.toPrimitive(),
            try futurePParams.toPrimitive(),
            pulsingState,
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
public struct GovernanceProposals: CBORSerializable, Sendable {
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
public struct PrevGovActionIds: CBORSerializable, Sendable {
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
public struct GovernanceProposal: CBORSerializable, Sendable {
    public let govActionId: GovActionID
    /// Votes cast by constitutional committee members (hot cred → vote).
    public let committeeVotes: [(credential: CommitteeHotCredential, vote: Vote)]
    /// Votes cast by DReps (DRep credential → vote).
    public let dRepVotes: [(credential: DRepCredential, vote: Vote)]
    /// Votes cast by stake pool operators (pool key hash → vote).
    public let stakePoolVotes: [(poolKeyHash: Data, vote: Vote)]
    public let proposalProcedure: ProposalProcedure
    public let proposedIn: UInt64
    public let expiresAfter: UInt64

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 7 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceProposal: expected list[7], got \(primitive)")
        }
        govActionId      = try GovActionID(from: f[0])
        committeeVotes   = try Self.decodeVotes(f[1]) { try CommitteeHotCredential(from: $0) }
        dRepVotes        = try Self.decodeVotes(f[2]) { try DRepCredential(from: $0) }
        stakePoolVotes   = try Self.decodeSPOVotes(f[3])
        proposalProcedure = try ProposalProcedure(from: f[4])
        proposedIn       = try Self.readUInt(f[5], label: "proposedIn")
        expiresAfter     = try Self.readUInt(f[6], label: "expiresAfter")
    }

    public func toPrimitive() throws -> Primitive {
        let committeeDict = try encodeCredVotes(committeeVotes)
        let dRepDict = try encodeCredVotes(dRepVotes)
        let spoDict = try encodeSPOVotes(stakePoolVotes)
        return .list([
            try govActionId.toPrimitive(),
            committeeDict,
            dRepDict,
            spoDict,
            try proposalProcedure.toPrimitive(),
            .uint(UInt(proposedIn)),
            .uint(UInt(expiresAfter)),
        ])
    }

    private static func decodeVotes<C: CBORSerializable>(
        _ p: Primitive,
        decode: (Primitive) throws -> C
    ) throws -> [(credential: C, vote: Vote)] {
        let pairs = orderedDictPairs(p)
        return try pairs.map { (k, v) in
            let cred = try decode(k)
            let vote = try readVote(v)
            return (cred, vote)
        }
    }

    private static func decodeSPOVotes(_ p: Primitive) throws -> [(poolKeyHash: Data, vote: Vote)] {
        let pairs = orderedDictPairs(p)
        return try pairs.map { (k, v) in
            guard case .bytes(let hash) = k else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "SPO vote: expected bytes key, got \(k)")
            }
            return (hash, try readVote(v))
        }
    }

    private static func orderedDictPairs(_ p: Primitive) -> [(Primitive, Primitive)] {
        switch p {
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .dict(let d): return d.map { ($0.key, $0.value) }
        default: return []
        }
    }

    private static func readVote(_ p: Primitive) throws -> Vote {
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

    private static func readUInt(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceProposal: expected uint for \(label)")
        }
    }

    private func encodeCredVotes<C: CBORSerializable>(
        _ votes: [(credential: C, vote: Vote)]
    ) throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in votes {
            pairs.append((try entry.credential.toPrimitive(), .uint(UInt(entry.vote.rawValue))))
        }
        return .dict(Dictionary(uniqueKeysWithValues: pairs))
    }

    private func encodeSPOVotes(_ votes: [(poolKeyHash: Data, vote: Vote)]) throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in votes {
            pairs.append((.bytes(entry.poolKeyHash), .uint(UInt(entry.vote.rawValue))))
        }
        return .dict(Dictionary(uniqueKeysWithValues: pairs))
    }
}

// MARK: - GovernanceCommitteeState

/// The constitutional committee membership state.
///
/// Wire: StrictMaybe wrapping list[2]:
///   [0] orderedDict{ CommitteeColdCred → expiryEpoch:uint }
///   [1] hot credential authorizations (orderedDict or empty indefiniteList)
public struct GovernanceCommitteeState: CBORSerializable, Sendable {
    /// Committee cold credentials and their term expiry epochs.
    public let members: [(coldCred: CommitteeColdCredential, expiryEpoch: UInt64)]
    /// Raw CBOR for the hot-credential authorization map (opaque — may be empty indefiniteList).
    public let hotAuthorizations: Primitive

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "GovernanceCommitteeState: expected list[2], got \(primitive)")
        }
        let pairs = Self.orderedDictPairs(f[0])
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
            return (cred, epoch)
        }
        hotAuthorizations = f[1]
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for m in members {
            pairs.append((try m.coldCred.toPrimitive(), .uint(UInt(m.expiryEpoch))))
        }
        return .list([
            .dict(Dictionary(uniqueKeysWithValues: pairs)),
            hotAuthorizations,
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

    private static func orderedDictPairs(_ p: Primitive) -> [(Primitive, Primitive)] {
        switch p {
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .dict(let d): return d.map { ($0.key, $0.value) }
        default: return []
        }
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
public enum FuturePParams: CBORSerializable, Sendable {
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
