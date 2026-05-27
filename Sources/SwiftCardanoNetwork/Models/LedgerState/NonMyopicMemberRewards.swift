import Foundation
import SwiftCardanoCore

/// Input to the `GetNonMyopicMemberRewards` query.
///
/// Each input is either a specific coin amount (stake) or a stake credential.
/// The node computes projected non-myopic reward for each.
public enum NonMyopicMemberRewardsInput: Sendable {
    /// A coin amount representing a hypothetical stake.
    case coin(UInt64)
    /// A stake credential for an existing account.
    case credential(StakeCredential)
}

extension NonMyopicMemberRewardsInput: Equatable {
    public static func == (lhs: NonMyopicMemberRewardsInput, rhs: NonMyopicMemberRewardsInput) -> Bool {
        switch (lhs, rhs) {
        case (.coin(let a), .coin(let b)): return a == b
        case (.credential(let a), .credential(let b)):
            return (try? a.toPrimitive()) == (try? b.toPrimitive())
        default: return false
        }
    }
}

extension NonMyopicMemberRewardsInput: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .coin(let v):
            0.hash(into: &hasher)
            v.hash(into: &hasher)
        case .credential(let c):
            1.hash(into: &hasher)
            if let p = try? c.toPrimitive() { p.hash(into: &hasher) }
        }
    }
}

/// A single entry in the non-myopic member rewards response.
public struct NonMyopicRewardEntry: Sendable, Equatable, Hashable {
    public let input: NonMyopicMemberRewardsInput
    /// Estimated rewards in lovelace.
    public let rewards: UInt64

    public init(input: NonMyopicMemberRewardsInput, rewards: UInt64) {
        self.input = input
        self.rewards = rewards
    }
}

/// Projected non-myopic member rewards for a set of stake inputs.
///
/// Returned by `GetNonMyopicMemberRewards` (query tag 2).
/// Wire format: `{ (coin | stake_credential) → coin_rewards }`
public struct NonMyopicMemberRewards: Serializable {
    public let entries: [NonMyopicRewardEntry]

    public init(entries: [NonMyopicRewardEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("NonMyopicMemberRewards: expected map")
        }
        entries = try pairs.map { (key, value) in
            let rewards = try Self.uint(from: value)
            let input: NonMyopicMemberRewardsInput
            switch key {
            case .uint(let v):
                input = .coin(UInt64(v))
            case .int(let v) where v >= 0:
                input = .coin(UInt64(v))
            default:
                input = .credential(try StakeCredential(from: key))
            }
            return NonMyopicRewardEntry(input: input, rewards: rewards)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            let keyPrim: Primitive
            switch entry.input {
            case .coin(let v): keyPrim = .uint(UInt64(v))
            case .credential(let c): keyPrim = try c.toPrimitive()
            }
            pairs.append((keyPrim, .uint(UInt64(entry.rewards))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: NonMyopicMemberRewards, rhs: NonMyopicMemberRewards) -> Bool {
        lhs.entries == rhs.entries
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("NonMyopicMemberRewards: expected uint for rewards")
        }
    }
}
