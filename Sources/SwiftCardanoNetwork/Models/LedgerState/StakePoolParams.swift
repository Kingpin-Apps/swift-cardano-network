import Foundation
import OrderedCollections
import SwiftCardanoCore

/// Per-pool parameters returned by `GetStakePoolParams` (query tag 17).
///
/// Wire format: `{ pool_key_hash: bytes28 → pool_params }` where `pool_params` is
/// the Ouroboros `PoolParams` CBOR structure.
public struct StakePoolParamsEntry: Serializable {
    public let poolOperator: PoolOperator
    /// The decoded pool parameters for this pool.
    public let params: PoolParams

    public init(poolOperator: PoolOperator, params: PoolParams) {
        self.poolOperator = poolOperator
        self.params = params
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "StakePoolParamsEntry: expected [poolOperator, params]")
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

    public static func == (lhs: StakePoolParamsEntry, rhs: StakePoolParamsEntry) -> Bool {
        guard let lp = try? lhs.params.toPrimitive(), let rp = try? rhs.params.toPrimitive() else {
            return false
        }
        return lhs.poolOperator == rhs.poolOperator && lp == rp
    }

    public func hash(into hasher: inout Hasher) {
        poolOperator.hash(into: &hasher)
        if let p = try? params.toPrimitive() { p.hash(into: &hasher) }
    }
}

/// Stake pool parameters for a set of pools.
///
/// Returned by `GetStakePoolParams` (query tag 17).
public struct StakePoolParams: Serializable {
    public let entries: [StakePoolParamsEntry]

    public init(entries: [StakePoolParamsEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakePoolParams: expected map")
        }
        entries = try pairs.map { (key, value) in
            let op = try PoolOperator(from: key)
            let params = try PoolParams(from: value)
            return StakePoolParamsEntry(poolOperator: op, params: params)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var dict: [(Primitive, Primitive)] = []
        for entry in entries {
            dict.append((try entry.poolOperator.toPrimitive(), try entry.params.toPrimitive()))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: dict))
    }

}
