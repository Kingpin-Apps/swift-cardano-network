import Foundation
import SwiftCardanoCore

/// A single entry mapping a stake credential to its delegated DRep.
public struct VoteDelegateeEntry: Sendable {
    /// The stake credential that performed the vote delegation.
    public let credential: StakeCredential
    /// The DRep to which votes are delegated.
    public let drep: DRep

    public init(credential: StakeCredential, drep: DRep) {
        self.credential = credential
        self.drep = drep
    }
}

extension VoteDelegateeEntry: Equatable {
    public static func == (lhs: VoteDelegateeEntry, rhs: VoteDelegateeEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && (try? lhs.drep.toPrimitive()) == (try? rhs.drep.toPrimitive())
    }
}

extension VoteDelegateeEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        if let p = try? drep.toPrimitive() { p.hash(into: &hasher) }
    }
}

/// Map of stake credentials to the DRep each has delegated their vote to.
///
/// Returned by `GetFilteredVoteDelegatees` (query tag 28).
/// Wire format: `{ stake_credential → drep }`
public struct VoteDelegatees: CBORSerializable, Sendable {
    public let entries: [VoteDelegateeEntry]

    public init(entries: [VoteDelegateeEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("VoteDelegatees: expected map")
        }
        entries = try pairs.map { (key, value) in
            let credential = try StakeCredential(from: key)
            let drep = try DRep(from: value)
            return VoteDelegateeEntry(credential: credential, drep: drep)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = try entry.credential.toPrimitive()
            let value = try entry.drep.toPrimitive()
            pairs.append((key, value))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: VoteDelegatees, rhs: VoteDelegatees) -> Bool {
        lhs.entries == rhs.entries
    }
}
