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
public enum HotCredentialStatus: Sendable {
    case authorised(CommitteeHotCredential)
    case notAuthorised
    case resigned(CommitteeHotCredential)
}

extension HotCredentialStatus: Equatable {
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
}

extension HotCredentialStatus: Hashable {
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
public enum MemberStatus: UInt64, Sendable, Equatable, Hashable {
    case active = 0
    case expired = 1
    case unrecognised = 2
}

/// The full state of a single constitutional committee member.
public struct CommitteeMemberState: Sendable, Equatable, Hashable {
    /// Hot credential authorisation status for this member.
    public let hotCredentialStatus: HotCredentialStatus
    /// Whether this member's term is currently active, expired, or unrecognised.
    public let memberStatus: MemberStatus
    /// Epoch at which this member's term ends, if defined (`StrictMaybe EpochNo`).
    public let termExpiry: UInt64?
    /// Raw `NextEpochChange` payload (kept opaque — typically a small enum tag).
    public let nextEpochChange: Primitive

    public init(
        hotCredentialStatus: HotCredentialStatus,
        memberStatus: MemberStatus,
        termExpiry: UInt64?,
        nextEpochChange: Primitive
    ) {
        self.hotCredentialStatus = hotCredentialStatus
        self.memberStatus = memberStatus
        self.termExpiry = termExpiry
        self.nextEpochChange = nextEpochChange
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
public struct CommitteeMembersState: CBORSerializable, Sendable {
    /// Map of cold credentials to their current member state.
    public let members: [(coldCredential: CommitteeColdCredential, state: CommitteeMemberState)]
    /// Current quorum threshold for committee votes, if set.
    public let threshold: Fraction?
    /// Current epoch at which this snapshot was taken.
    public let currentEpoch: UInt64

    public init(
        members: [(coldCredential: CommitteeColdCredential, state: CommitteeMemberState)],
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
            let coldCred = try CommitteeColdCredential(from: key)

            guard case .list(let entry) = value, entry.count >= 4 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "CommitteeMembersState: expected [hotCredStatus, memberStatus, expiry, nextEpochChange]")
            }

            let hotStatus = try Self.parseHotCredentialStatus(entry[0])

            let statusCode: UInt64
            switch entry[1] {
            case .uint(let u): statusCode = UInt64(u)
            case .int(let i) where i >= 0: statusCode = UInt64(i)
            default:
                throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: invalid member status")
            }
            guard let memberStatus = MemberStatus(rawValue: statusCode) else {
                throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: unknown member status \(statusCode)")
            }

            let termExpiry = try Self.parseStrictMaybeUInt64(entry[2], label: "termExpiry")

            let state = CommitteeMemberState(
                hotCredentialStatus: hotStatus,
                memberStatus: memberStatus,
                termExpiry: termExpiry,
                nextEpochChange: entry[3]
            )
            return (coldCredential: coldCred, state: state)
        }

        threshold = try Self.parseStrictMaybeFraction(outer[1], label: "threshold")

        switch outer[2] {
        case .uint(let u): currentEpoch = UInt64(u)
        case .int(let i) where i >= 0: currentEpoch = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected uint for currentEpoch")
        }
    }

    private static func parseHotCredentialStatus(_ prim: Primitive) throws -> HotCredentialStatus {
        guard case .list(let items) = prim, !items.isEmpty else {
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: invalid hotCredStatus encoding")
        }
        let code: UInt64
        switch items[0] {
        case .uint(let u): code = UInt64(u)
        case .int(let i) where i >= 0: code = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: invalid hotCredStatus tag")
        }
        switch code {
        case 0:
            guard items.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: Authorised missing hot credential")
            }
            return .authorised(try CommitteeHotCredential(from: items[1]))
        case 1:
            return .notAuthorised
        case 2:
            guard items.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: Resigned missing hot credential")
            }
            return .resigned(try CommitteeHotCredential(from: items[1]))
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: unknown hotCredStatus code \(code)")
        }
    }

    private static func parseStrictMaybeUInt64(_ prim: Primitive, label: String) throws -> UInt64? {
        guard case .list(let items) = prim else { return nil }
        guard let first = items.first else { return nil }
        switch first {
        case .uint(let u): return UInt64(u)
        case .int(let i) where i >= 0: return UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected uint for \(label)")
        }
    }

    private static func parseStrictMaybeFraction(_ prim: Primitive, label: String) throws -> Fraction? {
        guard case .list(let items) = prim, let first = items.first else { return nil }
        if case .unitInterval(let ui) = first {
            return Fraction(numerator: Int(ui.numerator), denominator: Int(ui.denominator))
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

    private static func readInt(_ prim: Primitive, label: String) throws -> Int {
        switch prim {
        case .int(let v): return v
        case .uint(let v): return Int(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("CommitteeMembersState: expected integer for \(label)")
        }
    }

    public func toPrimitive() throws -> Primitive {
        var memberPairs: [(Primitive, Primitive)] = []
        for (coldCred, state) in members {
            let hotPrim: Primitive
            switch state.hotCredentialStatus {
            case .authorised(let c):
                hotPrim = .list([.uint(0), try c.toPrimitive()])
            case .notAuthorised:
                hotPrim = .list([.uint(1)])
            case .resigned(let c):
                hotPrim = .list([.uint(2), try c.toPrimitive()])
            }
            let expiryPrim: Primitive = state.termExpiry.map { .list([.uint(UInt($0))]) } ?? .list([])
            let entryPrim: Primitive = .list([
                hotPrim,
                .uint(UInt(state.memberStatus.rawValue)),
                expiryPrim,
                state.nextEpochChange,
            ])
            memberPairs.append((try coldCred.toPrimitive(), entryPrim))
        }

        let thresholdPrim: Primitive = try threshold.map { try .list([$0.toPrimitive()]) } ?? .list([])

        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: memberPairs)),
            thresholdPrim,
            .uint(UInt(currentEpoch)),
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
        for (cred, state) in members {
            if let p = try? cred.toPrimitive() { p.hash(into: &hasher) }
            state.hash(into: &hasher)
        }
        threshold.hash(into: &hasher)
        currentEpoch.hash(into: &hasher)
    }
}
