import Foundation
import SwiftCardanoCore

// MARK: - EnactCommittee

/// The constitutional committee membership with its quorum threshold.
///
/// Wire: list[2]:
///   [0] orderedDict{ CommitteeColdCredential → expiryEpoch:uint }
///   [1] threshold: UnitInterval (CBOR tag-30 rational)
public struct EnactCommittee: Serializable {
    /// Committee members mapped to their term-expiry epoch.
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
                "EnactCommittee: expected list[2], got \(primitive)")
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
                    "EnactCommittee: expected uint expiry, got \(v)")
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

    static func fromStrictMaybe(_ p: Primitive) throws -> EnactCommittee? {
        guard case .list(let items) = p else { return nil }
        if items.isEmpty { return nil }
        return try EnactCommittee(from: items[0])
    }

    static func toStrictMaybe(_ committee: EnactCommittee?) throws -> Primitive {
        guard let committee else { return .list([]) }
        return .list([try committee.toPrimitive()])
    }

    private static func dictPairs(_ p: Primitive) -> [(Primitive, Primitive)] {
        switch p {
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .dict(let d): return d.map { ($0.key, $0.value) }
        default: return []
        }
    }
}

extension EnactCommittee {
    public static func == (lhs: EnactCommittee, rhs: EnactCommittee) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

// MARK: - EnactState

/// The enacted governance state at the current epoch boundary.
///
/// Wire format: CBOR list of 7 fields (Haskell ToCBOR order for Conway EnactState):
///   [0] committee        — StrictMaybe(EnactCommittee): list[0]=Nothing, list[1][c]=Just(c)
///   [1] constitution     — list[2]: [anchor, optional scriptHash]
///   [2] curPParams       — 31-field positional list (n2c ProtocolParameters encoding)
///   [3] prevPParams      — 31-field positional list
///   [4] treasury         — uint (Coin in lovelace)
///   [5] withdrawals      — map of StakeCredential → Coin (usually empty)
///   [6] prevGovActionIds — list[4] of StrictMaybe(GovActionID)
/// A pending treasury withdrawal: where the funds are sent and how much.
public struct TreasuryWithdrawal: Serializable {
    public let credential: StakeCredential
    public let coin: UInt64

    public init(credential: StakeCredential, coin: UInt64) {
        self.credential = credential
        self.coin = coin
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "TreasuryWithdrawal: expected [credential, coin]")
        }
        credential = try StakeCredential(from: f[0])
        switch f[1] {
        case .uint(let u):              coin = UInt64(u)
        case .int(let i) where i >= 0:  coin = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "TreasuryWithdrawal: expected uint coin")
        }
    }

    public func toPrimitive() throws -> Primitive {
        .list([try credential.toPrimitive(), .uint(UInt(coin))])
    }
}

public struct EnactState: Serializable {
    /// Constitutional committee membership and quorum threshold (nil if no committee).
    public let committee: EnactCommittee?
    /// The current ratified constitution.
    public let constitution: Constitution
    /// Current protocol parameters.
    public let currentPParams: ProtocolParameters
    /// Previous epoch's protocol parameters.
    public let prevPParams: ProtocolParameters
    /// Treasury balance in lovelace.
    public let treasury: UInt64
    /// Pending treasury withdrawals authorised but not yet disbursed (usually empty).
    public let withdrawals: [TreasuryWithdrawal]
    /// Most recently enacted GovActionID per governance action type.
    public let prevGovActionIds: PrevGovActionIds

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 7 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "EnactState: expected list[7+], got \(primitive)")
        }
        committee        = try EnactCommittee.fromStrictMaybe(f[0])
        constitution     = try Constitution(from: f[1])
        currentPParams   = try ProtocolParameters(from: f[2])
        prevPParams      = try ProtocolParameters(from: f[3])
        treasury         = try Self.readUInt(f[4], label: "treasury")
        withdrawals      = try Self.parseWithdrawals(f[5])
        prevGovActionIds = try PrevGovActionIds(from: f[6])
    }

    public func toPrimitive() throws -> Primitive {
        var wdPairs: [(Primitive, Primitive)] = []
        for w in withdrawals {
            wdPairs.append((try w.credential.toPrimitive(), .uint(UInt(w.coin))))
        }
        return .list([
            try EnactCommittee.toStrictMaybe(committee),
            try constitution.toPrimitive(),
            try currentPParams.toPrimitive(),
            try prevPParams.toPrimitive(),
            .uint(UInt(treasury)),
            .dict(Dictionary(uniqueKeysWithValues: wdPairs)),
            try prevGovActionIds.toPrimitive(),
        ])
    }

    private static func readUInt(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "EnactState: expected uint for \(label), got \(p)")
        }
    }

    private static func parseWithdrawals(_ p: Primitive) throws -> [TreasuryWithdrawal] {
        let pairs: [(Primitive, Primitive)]
        switch p {
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .dict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "EnactState: expected map for withdrawals, got \(p)")
        }
        return try pairs.map { (k, v) in
            let credential = try StakeCredential(from: k)
            let coin = try readUInt(v, label: "withdrawal coin")
            return TreasuryWithdrawal(credential: credential, coin: coin)
        }
    }

    public static func == (lhs: EnactState, rhs: EnactState) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

// MARK: - RatifyState

/// The current ratification state (post-ratification, pre-epoch-boundary).
///
/// Returned by `GetRatifyState` (query tag 32).
///
/// Wire format: CBOR list of 4 fields:
///   [0] enactState — EnactState (list[7])
///   [1] enacted    — list of full GovActionState (proposals ratified this epoch)
///   [2] expired    — CBOR tag-258 set of GovActionID (expired without ratification)
///   [3] delayed    — bool (true if HardFork ratification is pending node upgrades)
public struct RatifyState: Serializable {
    /// The enacted governance state at the current epoch boundary.
    public let enactState: EnactState
    /// Governance proposals that were ratified and enacted this epoch.
    public let enacted: [GovernanceProposal]
    /// IDs of proposals that expired without reaching the ratification threshold.
    public let expired: [GovActionID]
    /// Whether ratification was delayed past this epoch boundary.
    public let delayed: Bool

    public init(
        enactState: EnactState,
        enacted: [GovernanceProposal],
        expired: [GovActionID],
        delayed: Bool
    ) {
        self.enactState = enactState
        self.enacted = enacted
        self.expired = expired
        self.delayed = delayed
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let fields) = primitive, fields.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "RatifyState: expected list[4+], got \(primitive)")
        }

        enactState = try EnactState(from: fields[0])

        guard case .list(let enactedList) = fields[1] else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "RatifyState: expected list for enacted, got \(fields[1])")
        }
        enacted = try enactedList.map { try GovernanceProposal(from: $0) }

        expired = try Self.parseExpiredSet(fields[2])

        switch fields[3] {
        case .bool(let b): delayed = b
        case .uint(let u): delayed = u != 0
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RatifyState: expected bool for delayed, got \(fields[3])")
        }
    }

    private static func parseExpiredSet(_ primitive: Primitive) throws -> [GovActionID] {
        let items: [Primitive]
        switch primitive {
        case .list(let l):
            items = l
        case .cborTag(let t) where t.tag == 258:
            if case .list(let l) = t.value { items = l } else { items = [] }
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "RatifyState: expected list or tag-258 set for expired, got \(primitive)")
        }
        return try items.map { try GovActionID(from: $0) }
    }

    public func toPrimitive() throws -> Primitive {
        let enactedPrim = Primitive.list(try enacted.map { try $0.toPrimitive() })
        let expiredPrim = Primitive.list(try expired.map { try $0.toPrimitive() })
        return .list([
            try enactState.toPrimitive(),
            enactedPrim,
            expiredPrim,
            .bool(delayed),
        ])
    }

    public static func == (lhs: RatifyState, rhs: RatifyState) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}
