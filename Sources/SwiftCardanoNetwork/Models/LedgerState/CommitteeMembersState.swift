import Foundation
import SwiftCardanoCore

// MARK: - Filter (query input)

/// Filters for `GetCommitteeMembersState` (query tag 27).
///
/// Empty / nil filter sets mean "no filter" (return all).
/// Encode as three Tag-258 sets: `[cold_creds, hot_creds, statuses]`.
public struct CommitteeMembersFilter: Sendable {
    /// Filter by cold committee credentials; nil or empty means all.
    public let coldCredentials: [CommitteeColdCredential]?
    /// Filter by hot committee credentials; nil or empty means all.
    public let hotCredentials: [CommitteeHotCredential]?

    public init(
        coldCredentials: [CommitteeColdCredential]? = nil,
        hotCredentials: [CommitteeHotCredential]? = nil
    ) {
        self.coldCredentials = coldCredentials
        self.hotCredentials = hotCredentials
    }

    /// A filter that returns all committee members.
    public static var all: CommitteeMembersFilter {
        CommitteeMembersFilter()
    }
}

// MARK: - Supporting types

/// Whether a committee member's hot credential is authorised, not authorised, or resigned.
///
/// Wire format:
/// - `[0, hot_credential]` = Authorised
/// - `[1]`                 = NotAuthorised
/// - `[2, hot_credential]` = Resigned (with the credential used when resigning)
public enum HotCredentialStatus: Serializable {
    case authorised(CommitteeHotCredential)
    case notAuthorised
    case resigned(CommitteeHotCredential)

    public init(from primitive: Primitive) throws {
        guard case .list(let items) = primitive, !items.isEmpty else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "HotCredentialStatus: expected non-empty list")
        }
        let code: UInt64
        switch items[0] {
        case .uint(let u): code = UInt64(u)
        case .int(let i) where i >= 0: code = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "HotCredentialStatus: invalid tag")
        }
        switch code {
        case 0:
            guard items.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "HotCredentialStatus: Authorised missing credential")
            }
            self = .authorised(try CommitteeHotCredential(from: items[1]))
        case 1:
            self = .notAuthorised
        case 2:
            guard items.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "HotCredentialStatus: Resigned missing credential")
            }
            self = .resigned(try CommitteeHotCredential(from: items[1]))
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "HotCredentialStatus: unknown tag \(code)")
        }
    }

    public func toPrimitive() throws -> Primitive {
        switch self {
        case .authorised(let c):  return .list([.uint(0), try c.toPrimitive()])
        case .notAuthorised:      return .list([.uint(1)])
        case .resigned(let c):    return .list([.uint(2), try c.toPrimitive()])
        }
    }
}

extension HotCredentialStatus {
    public static func == (lhs: HotCredentialStatus, rhs: HotCredentialStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notAuthorised, .notAuthorised): return true
        case (.authorised(let l), .authorised(let r)):
            return (try? l.toPrimitive()) == (try? r.toPrimitive())
        case (.resigned(let l), .resigned(let r)):
            return (try? l.toPrimitive()) == (try? r.toPrimitive())
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .notAuthorised: hasher.combine(1)
        case .authorised(let c):
            hasher.combine(0)
            if let p = try? c.toPrimitive() { p.hash(into: &hasher) }
        case .resigned(let c):
            hasher.combine(2)
            if let p = try? c.toPrimitive() { p.hash(into: &hasher) }
        }
    }
}

/// The authorisation status of a committee member (Active, Expired, or Unrecognised).
///
/// Wire format: integer 0 = Active, 1 = Expired, 2 = Unrecognised.
public enum MemberStatus: UInt64, Serializable {
    case active = 0
    case expired = 1
    case unrecognised = 2

    public init(from primitive: Primitive) throws {
        let code: UInt64
        switch primitive {
        case .uint(let u): code = UInt64(u)
        case .int(let i) where i >= 0: code = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("MemberStatus: expected uint")
        }
        guard let v = MemberStatus(rawValue: code) else {
            throw LedgerStateDecodingError.unexpectedFormat("MemberStatus: unknown code \(code)")
        }
        self = v
    }

    public func toPrimitive() throws -> Primitive {
        .uint(UInt64(rawValue))
    }
}

/// The anticipated change to a committee member's status next epoch.
///
/// Wire format: a CBOR list where the first element is the tag:
/// - `[0]` = NoChangeExpiration — term expiry unchanged
/// - `[1]` = NoChangeTermExpiration — no term-expiration change
/// - `[2, epochNo]` = TermAdjusted — term adjusted to the given epoch
/// - `[3]` = MemberNotFound — member not found in the next committee
public enum NextEpochChange: Serializable {
    case noChangeExpiration
    case noChangeTermExpiration
    case termAdjusted(UInt64)
    case memberNotFound

    public init(from primitive: Primitive) throws {
        guard case .list(let items) = primitive, !items.isEmpty else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "NextEpochChange: expected non-empty list")
        }
        let tag: UInt64
        switch items[0] {
        case .uint(let u): tag = UInt64(u)
        case .int(let i) where i >= 0: tag = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "NextEpochChange: expected uint tag, got \(items[0])")
        }
        switch tag {
        case 0: self = .noChangeExpiration
        case 1: self = .noChangeTermExpiration
        case 2:
            guard items.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "NextEpochChange: TermAdjusted missing epochNo")
            }
            switch items[1] {
            case .uint(let u): self = .termAdjusted(UInt64(u))
            case .int(let i) where i >= 0: self = .termAdjusted(UInt64(i))
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "NextEpochChange: TermAdjusted epochNo must be uint")
            }
        case 3: self = .memberNotFound
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "NextEpochChange: unknown tag \(tag)")
        }
    }

    public func toPrimitive() throws -> Primitive {
        switch self {
        case .noChangeExpiration:     return .list([.uint(0)])
        case .noChangeTermExpiration: return .list([.uint(1)])
        case .termAdjusted(let e):   return .list([.uint(2), .uint(UInt64(e))])
        case .memberNotFound:         return .list([.uint(3)])
        }
    }
}

extension NextEpochChange: Equatable {
    public static func == (lhs: NextEpochChange, rhs: NextEpochChange) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }
}

extension NextEpochChange: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}

/// The full state of a single constitutional committee member.
public struct CommitteeMemberState: Serializable {
    /// Hot credential authorisation status for this member.
    public let hotCredentialStatus: HotCredentialStatus
    /// Whether this member's term is currently active, expired, or unrecognised.
    public let memberStatus: MemberStatus
    /// Epoch at which this member's term ends, if defined (`StrictMaybe EpochNo`).
    public let termExpiry: UInt64?
    /// The anticipated change to this member's status at the next epoch boundary.
    public let nextEpochChange: NextEpochChange

    public init(
        hotCredentialStatus: HotCredentialStatus,
        memberStatus: MemberStatus,
        termExpiry: UInt64?,
        nextEpochChange: NextEpochChange
    ) {
        self.hotCredentialStatus = hotCredentialStatus
        self.memberStatus = memberStatus
        self.termExpiry = termExpiry
        self.nextEpochChange = nextEpochChange
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CommitteeMemberState: expected [hotCredStatus, memberStatus, expiry, nextEpochChange]")
        }
        hotCredentialStatus = try HotCredentialStatus(from: f[0])
        memberStatus        = try MemberStatus(from: f[1])
        termExpiry          = Self.decodeStrictMaybeUInt64(f[2])
        nextEpochChange     = try NextEpochChange(from: f[3])
    }

    public func toPrimitive() throws -> Primitive {
        let expiryPrim: Primitive = termExpiry.map { .list([.uint(UInt64($0))]) } ?? .list([])
        return .list([
            try hotCredentialStatus.toPrimitive(),
            try memberStatus.toPrimitive(),
            expiryPrim,
            try nextEpochChange.toPrimitive(),
        ])
    }

    private static func decodeStrictMaybeUInt64(_ p: Primitive) -> UInt64? {
        guard case .list(let items) = p, let first = items.first else { return nil }
        switch first {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default: return nil
        }
    }
}

// MARK: - Response

/// The current state of constitutional committee members.
///
/// Returned by `GetCommitteeMembersState` (query tag 27).
///
/// Wire format: a CBOR list `[membersState, threshold, currentEpoch]` where:
/// - `membersState`: `{ cold_credential → [hotCredStatus, memberStatus, [expiry?], [nextEpochChange]] }`
///   - `hotCredStatus`: `[0, hot_cred]` = Authorised, `[1]` = NotAuthorised, `[2, hot_cred]` = Resigned
///   - `memberStatus`: 0 = Active, 1 = Expired, 2 = Unrecognised
///   - `expiry`: `StrictMaybe EpochNo` — `[]` (none) or `[epochNo]`
///   - `nextEpochChange`: opaque enum payload (e.g. `[2]`)
/// - `threshold`: `StrictMaybe (tag-30 Fraction)` — `[]` (none) or `[fraction]`
/// - `currentEpoch`: `UInt64`
/// A single committee member's full state record (cold credential paired with
/// hot-credential authorisation status, member status, expiry, and pending
/// next-epoch change).
public struct CommitteeMemberStateEntry: Serializable {
    public let coldCredential: CommitteeColdCredential
    public let state: CommitteeMemberState

    public init(coldCredential: CommitteeColdCredential, state: CommitteeMemberState) {
        self.coldCredential = coldCredential
        self.state = state
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CommitteeMemberStateEntry: expected [coldCredential, state]")
        }
        coldCredential = try CommitteeColdCredential(from: f[0])
        state          = try CommitteeMemberState(from: f[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([try coldCredential.toPrimitive(), try state.toPrimitive()])
    }
}

public struct CommitteeMembersState: Serializable {
    /// Map of cold credentials to their current member state.
    public let members: [CommitteeMemberStateEntry]
    /// Current quorum threshold for committee votes, if set.
    public let threshold: Fraction?
    /// Current epoch at which this snapshot was taken.
    public let currentEpoch: UInt64

    public init(
        members: [CommitteeMemberStateEntry],
        threshold: Fraction?,
        currentEpoch: UInt64
    ) {
        self.members = members
        self.threshold = threshold
        self.currentEpoch = currentEpoch
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let outer) = primitive, outer.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CommitteeMembersState: expected list of 3+ elements")
        }

        let pairs: [(Primitive, Primitive)]
        switch outer[0] {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d): pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected map for membersState")
        }

        members = try pairs.map { (key, value) in
            CommitteeMemberStateEntry(
                coldCredential: try CommitteeColdCredential(from: key),
                state: try CommitteeMemberState(from: value)
            )
        }

        threshold = try Self.parseStrictMaybeFraction(outer[1], label: "threshold")

        switch outer[2] {
        case .uint(let u): currentEpoch = UInt64(u)
        case .int(let i) where i >= 0: currentEpoch = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected uint for currentEpoch")
        }
    }

    private static func parseStrictMaybeFraction(_ prim: Primitive, label: String) throws -> Fraction? {
        guard case .list(let items) = prim, let first = items.first else { return nil }
        if case .unitInterval(let ui) = first {
            return Fraction(numerator: Int64(ui.numerator), denominator: Int64(ui.denominator))
        }
        if case .cborTag(let tag) = first, tag.tag == 30, case .list(let elems) = tag.value, elems.count == 2 {
            return Fraction(
                numerator: try readInt(elems[0], label: "\(label).numerator"),
                denominator: try readInt(elems[1], label: "\(label).denominator")
            )
        }
        if case .list(let elems) = first, elems.count == 2 {
            return Fraction(
                numerator: try readInt(elems[0], label: "\(label).numerator"),
                denominator: try readInt(elems[1], label: "\(label).denominator")
            )
        }
        throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected rational for \(label), got \(first)")
    }

    private static func readInt(_ prim: Primitive, label: String) throws -> Int64 {
        switch prim {
        case .int(let v): return v
        case .uint(let v): return Int64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected integer for \(label)")
        }
    }

    public func toPrimitive() throws -> Primitive {
        var memberPairs: [(Primitive, Primitive)] = []
        for entry in members {
            memberPairs.append(
                (try entry.coldCredential.toPrimitive(), try entry.state.toPrimitive())
            )
        }

        let thresholdPrim: Primitive = try threshold.map { try .list([$0.toPrimitive()]) } ?? .list([])

        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: memberPairs)),
            thresholdPrim,
            .uint(UInt64(currentEpoch)),
        ])
    }

    public static func == (lhs: CommitteeMembersState, rhs: CommitteeMembersState) -> Bool {
        guard lhs.members.count == rhs.members.count else { return false }
        for (l, r) in zip(lhs.members, rhs.members) {
            guard l.state == r.state,
                  (try? l.coldCredential.toPrimitive()) == (try? r.coldCredential.toPrimitive())
            else { return false }
        }
        return lhs.threshold == rhs.threshold && lhs.currentEpoch == rhs.currentEpoch
    }

    public func hash(into hasher: inout Hasher) {
        for entry in members {
            if let p = try? entry.coldCredential.toPrimitive() { p.hash(into: &hasher) }
            entry.state.hash(into: &hasher)
        }
        threshold.hash(into: &hasher)
        currentEpoch.hash(into: &hasher)
    }
}
