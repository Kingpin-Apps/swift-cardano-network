import Foundation
import SwiftCardanoCore

/// A single delegation entry: stake credential → pool key hash (if delegated).
public struct DelegationEntry: Sendable {
    public let credential: StakeCredential
    public let poolKeyHash: Data?

    public init(credential: StakeCredential, poolKeyHash: Data?) {
        self.credential = credential
        self.poolKeyHash = poolKeyHash
    }
}

extension DelegationEntry: Equatable {
    public static func == (lhs: DelegationEntry, rhs: DelegationEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && lhs.poolKeyHash == rhs.poolKeyHash
    }
}

extension DelegationEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        poolKeyHash.hash(into: &hasher)
    }
}

/// A single reward account entry: stake credential → lovelace balance.
public struct RewardAccountEntry: Sendable {
    public let credential: StakeCredential
    public let lovelace: UInt64

    public init(credential: StakeCredential, lovelace: UInt64) {
        self.credential = credential
        self.lovelace = lovelace
    }
}

extension RewardAccountEntry: Equatable {
    public static func == (lhs: RewardAccountEntry, rhs: RewardAccountEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && lhs.lovelace == rhs.lovelace
    }
}

extension RewardAccountEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        lovelace.hash(into: &hasher)
    }
}

/// Filtered delegations and reward account summaries for a set of stake credentials.
///
/// Returned by `GetFilteredDelegationsAndRewardAccounts` (query tag 10).
/// Wire format: `[{ credential → pool_key_hash | null }, { credential → lovelace }]`
public struct FilteredDelegationsAndRewards: CBORSerializable, Sendable {
    public let delegations: [DelegationEntry]
    public let rewardAccounts: [RewardAccountEntry]

    public init(delegations: [DelegationEntry], rewardAccounts: [RewardAccountEntry]) {
        self.delegations = delegations
        self.rewardAccounts = rewardAccounts
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let elems) = primitive, elems.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "FilteredDelegationsAndRewards: expected [delegations_map, rewards_map]"
            )
        }
        delegations = try Self.parseDelegations(from: elems[0])
        rewardAccounts = try Self.parseRewards(from: elems[1])
    }

    private static func parseDelegations(from primitive: Primitive) throws -> [DelegationEntry] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("FilteredDelegationsAndRewards: delegations must be a map")
        }
        return try pairs.map { (key, value) in
            let credential = try StakeCredential(from: key)
            let poolKeyHash: Data?
            switch value {
            case .bytes(let d): poolKeyHash = d
            case .byteArray(let b): poolKeyHash = Data(b)
            case .null: poolKeyHash = nil
            default:
                throw LedgerStateDecodingError.unexpectedFormat("FilteredDelegationsAndRewards: delegation value must be bytes or null")
            }
            return DelegationEntry(credential: credential, poolKeyHash: poolKeyHash)
        }
    }

    private static func parseRewards(from primitive: Primitive) throws -> [RewardAccountEntry] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("FilteredDelegationsAndRewards: rewards must be a map")
        }
        return try pairs.map { (key, value) in
            let credential = try StakeCredential(from: key)
            let lovelace: UInt64
            switch value {
            case .uint(let v): lovelace = UInt64(v)
            case .int(let v): lovelace = UInt64(v)
            default:
                throw LedgerStateDecodingError.unexpectedFormat("FilteredDelegationsAndRewards: reward value must be uint")
            }
            return RewardAccountEntry(credential: credential, lovelace: lovelace)
        }
    }

    public func toPrimitive() throws -> Primitive {
        let delegPairs = try delegations.map { entry -> (Primitive, Primitive) in
            let key = try entry.credential.toPrimitive()
            let val: Primitive = entry.poolKeyHash.map { .bytes($0) } ?? .null
            return (key, val)
        }
        let rewardPairs = try rewardAccounts.map { entry -> (Primitive, Primitive) in
            let key = try entry.credential.toPrimitive()
            return (key, .uint(UInt(entry.lovelace)))
        }
        let delegMap = Primitive.frozenDict(Dictionary(uniqueKeysWithValues: delegPairs))
        let rewardMap = Primitive.frozenDict(Dictionary(uniqueKeysWithValues: rewardPairs))
        return .list([delegMap, rewardMap])
    }

    public func hash(into hasher: inout Hasher) {
        delegations.hash(into: &hasher)
        rewardAccounts.hash(into: &hasher)
    }

    public static func == (lhs: FilteredDelegationsAndRewards, rhs: FilteredDelegationsAndRewards) -> Bool {
        lhs.delegations == rhs.delegations && lhs.rewardAccounts == rhs.rewardAccounts
    }
}
