import Foundation
import SwiftCardanoCore

/// A single entry mapping a stake credential to its delegation deposit.
public struct StakeDelegDepositEntry: Sendable {
    /// The stake credential this entry belongs to.
    public let credential: StakeCredential
    /// Deposit amount in lovelace.
    public let deposit: UInt64

    public init(credential: StakeCredential, deposit: UInt64) {
        self.credential = credential
        self.deposit = deposit
    }
}

extension StakeDelegDepositEntry: Equatable {
    public static func == (lhs: StakeDelegDepositEntry, rhs: StakeDelegDepositEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive()) && lhs.deposit == rhs.deposit
    }
}

extension StakeDelegDepositEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        deposit.hash(into: &hasher)
    }
}

/// Map of stake credentials to their current delegation deposit amounts.
///
/// Returned by `GetStakeDelegDeposits` (query tag 22).
/// Wire format: `{ stake_credential → coin }`
public struct StakeDelegDeposits: Serializable {
    public let entries: [StakeDelegDepositEntry]

    public init(entries: [StakeDelegDepositEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakeDelegDeposits: expected map")
        }
        entries = try pairs.map { (key, value) in
            let credential = try StakeCredential(from: key)
            let deposit = try Self.uint(from: value)
            return StakeDelegDepositEntry(credential: credential, deposit: deposit)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = try entry.credential.toPrimitive()
            pairs.append((key, .uint(UInt(entry.deposit))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: StakeDelegDeposits, rhs: StakeDelegDeposits) -> Bool {
        lhs.entries == rhs.entries
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakeDelegDeposits: expected uint for deposit")
        }
    }
}
