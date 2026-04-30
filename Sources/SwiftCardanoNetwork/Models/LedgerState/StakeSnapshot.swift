import Foundation
import OrderedCollections
import SwiftCardanoCore

// MARK: - SnapshotStakeEntry

/// A single stake entry: stake credential → lovelace.
public struct SnapshotStakeEntry: Serializable {
    public let credential: StakeCredential
    public let lovelace: UInt64

    public init(credential: StakeCredential, lovelace: UInt64) {
        self.credential = credential
        self.lovelace = lovelace
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "SnapshotStakeEntry: expected [credential, lovelace]")
        }
        credential = try StakeCredential(from: f[0])
        switch f[1] {
        case .uint(let u):              lovelace = UInt64(u)
        case .int(let i) where i >= 0:  lovelace = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("SnapshotStakeEntry: expected uint lovelace")
        }
    }

    public func toPrimitive() throws -> Primitive {
        .list([try credential.toPrimitive(), .uint(UInt(lovelace))])
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("credential")] = try credential.toPrimitive()
        dict[.string("lovelace")]   = .uint(UInt(lovelace))
        return .orderedDict(dict)
    }

    public static func == (lhs: SnapshotStakeEntry, rhs: SnapshotStakeEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && lhs.lovelace == rhs.lovelace
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        lovelace.hash(into: &hasher)
    }
}

// MARK: - SnapshotDelegationEntry

/// A single delegation entry: stake credential → pool operator.
public struct SnapshotDelegationEntry: Serializable {
    public let credential: StakeCredential
    /// Stake-pool operator (bech32 `pool…` ID; underlying 28-byte key hash).
    public let poolOperator: PoolOperator

    public init(credential: StakeCredential, poolOperator: PoolOperator) {
        self.credential = credential
        self.poolOperator = poolOperator
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "SnapshotDelegationEntry: expected [credential, poolOperator]")
        }
        credential   = try StakeCredential(from: f[0])
        poolOperator = try PoolOperator(from: f[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([try credential.toPrimitive(), try poolOperator.toPrimitive()])
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("credential")]   = try credential.toPrimitive()
        dict[.string("poolOperator")] = try poolOperator.toDict()
        return .orderedDict(dict)
    }

    public static func == (lhs: SnapshotDelegationEntry, rhs: SnapshotDelegationEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && lhs.poolOperator == rhs.poolOperator
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        poolOperator.hash(into: &hasher)
    }
}

// MARK: - SnapshotPoolParamEntry

/// A single pool parameter entry: pool operator → PoolParams.
public struct SnapshotPoolParamEntry: Serializable {
    /// Stake-pool operator (bech32 `pool…` ID; underlying 28-byte key hash).
    public let poolOperator: PoolOperator
    /// Registered pool parameters at this snapshot boundary.
    public let params: PoolParams

    public init(poolOperator: PoolOperator, params: PoolParams) {
        self.poolOperator = poolOperator
        self.params = params
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "SnapshotPoolParamEntry: expected [poolOperator, params]")
        }
        poolOperator = try PoolOperator(from: f[0])
        params       = try PoolParams(from: f[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([try poolOperator.toPrimitive(), try params.toPrimitive()])
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("poolOperator")] = try poolOperator.toDict()
        dict[.string("params")]       = try params.toPrimitive()
        return .orderedDict(dict)
    }

    public static func == (lhs: SnapshotPoolParamEntry, rhs: SnapshotPoolParamEntry) -> Bool {
        lhs.poolOperator == rhs.poolOperator
            && (try? lhs.params.toPrimitive()) == (try? rhs.params.toPrimitive())
    }

    public func hash(into hasher: inout Hasher) {
        poolOperator.hash(into: &hasher)
    }
}

// MARK: - StakeSnapshot

/// One stake snapshot (mark, set, or go) taken at an epoch boundary.
///
/// Wire format: a 3-element CBOR list:
/// ```
/// [stakeVMap, delegationsVMap, poolParamsVMap]
/// ```
/// All three are sorted CBOR dicts (VMap) with credential/key-hash keys:
/// - `stakeVMap`:       `{ StakeCredential → Lovelace }` — active stake per credential.
/// - `delegationsVMap`: `{ StakeCredential → bytes(28) }` — pool key hash per delegator.
/// - `poolParamsVMap`:  `{ bytes(28) → PoolParams }` — registered pool parameters.
public struct StakeSnapshot: Serializable {

    /// Stake distribution at this snapshot: credential → lovelace.
    public let stake: [SnapshotStakeEntry]

    /// Delegation map at this snapshot: credential → pool key hash.
    public let delegations: [SnapshotDelegationEntry]

    /// Pool parameters at this snapshot: pool key hash → PoolParams.
    public let poolParams: [SnapshotPoolParamEntry]

    public init(
        stake: [SnapshotStakeEntry] = [],
        delegations: [SnapshotDelegationEntry] = [],
        poolParams: [SnapshotPoolParamEntry] = []
    ) {
        self.stake       = stake
        self.delegations = delegations
        self.poolParams  = poolParams
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "StakeSnapshot: expected list, got \(primitive)")
        }
        // Lenient: fall back to empty when elements are missing (e.g. unit tests or pre-Conway).
        stake       = f.count > 0 ? (try? Self.parseStakeMap(f[0])) ?? [] : []
        delegations = f.count > 1 ? (try? Self.parseDelegationsMap(f[1])) ?? [] : []
        poolParams  = f.count > 2 ? (try? Self.parsePoolParamsMap(f[2])) ?? [] : []
    }

    public func toPrimitive() throws -> Primitive {
        var stakePairs: [(Primitive, Primitive)] = []
        for entry in stake {
            stakePairs.append((try entry.credential.toPrimitive(), .uint(UInt(entry.lovelace))))
        }
        var delegPairs: [(Primitive, Primitive)] = []
        for entry in delegations {
            delegPairs.append((try entry.credential.toPrimitive(), try entry.poolOperator.toPrimitive()))
        }
        var poolPairs: [(Primitive, Primitive)] = []
        for entry in poolParams {
            poolPairs.append((try entry.poolOperator.toPrimitive(), try entry.params.toPrimitive()))
        }
        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: stakePairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: delegPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: poolPairs)),
        ])
    }

    // MARK: - Private helpers

    private static func parseStakeMap(_ primitive: Primitive) throws -> [SnapshotStakeEntry] {
        try mapPairs(primitive, label: "stakeVMap").map { (key, value) in
            SnapshotStakeEntry(
                credential: try StakeCredential(from: key),
                lovelace: try uint(value, label: "stake lovelace")
            )
        }
    }

    private static func parseDelegationsMap(
        _ primitive: Primitive
    ) throws -> [SnapshotDelegationEntry] {
        try mapPairs(primitive, label: "delegationsVMap").map { (key, value) in
            SnapshotDelegationEntry(
                credential: try StakeCredential(from: key),
                poolOperator: try PoolOperator(from: value)
            )
        }
    }

    private static func parsePoolParamsMap(
        _ primitive: Primitive
    ) throws -> [SnapshotPoolParamEntry] {
        try mapPairs(primitive, label: "poolParamsVMap").map { (key, value) in
            SnapshotPoolParamEntry(
                poolOperator: try PoolOperator(from: key),
                params: try PoolParams(from: value)
            )
        }
    }

    private static func mapPairs(
        _ primitive: Primitive,
        label: String
    ) throws -> [(Primitive, Primitive)] {
        switch primitive {
        case .dict(let d):        return Array(d)
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  return Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "StakeSnapshot: expected map for \(label)")
        }
    }

    private static func uint(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "StakeSnapshot: expected uint for \(label)")
        }
    }

}

extension StakeSnapshot: Equatable {
    public static func == (lhs: StakeSnapshot, rhs: StakeSnapshot) -> Bool {
        lhs.stake == rhs.stake
            && lhs.delegations == rhs.delegations
            && lhs.poolParams == rhs.poolParams
    }
}

extension StakeSnapshot: Hashable {
    public func hash(into hasher: inout Hasher) {
        stake.count.hash(into: &hasher)
    }
}
