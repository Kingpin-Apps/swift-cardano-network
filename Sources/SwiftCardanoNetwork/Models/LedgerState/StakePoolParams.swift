import Foundation
import SwiftCardanoCore

/// Per-pool parameters returned by `GetStakePoolParams` (query tag 17).
///
/// Wire format: `{ pool_key_hash: bytes28 → pool_params }` where `pool_params` is
/// the Ouroboros `PoolParams` CBOR structure.
public struct StakePoolParamsEntry: Sendable {
    public let poolKeyHash: Data
    /// The decoded pool parameters for this pool.
    public let params: PoolParams

    public init(poolKeyHash: Data, params: PoolParams) {
        self.poolKeyHash = poolKeyHash
        self.params = params
    }
}

extension StakePoolParamsEntry: Equatable {
    public static func == (lhs: StakePoolParamsEntry, rhs: StakePoolParamsEntry) -> Bool {
        guard let lp = try? lhs.params.toPrimitive(), let rp = try? rhs.params.toPrimitive() else {
            return false
        }
        return lhs.poolKeyHash == rhs.poolKeyHash && lp == rp
    }
}

extension StakePoolParamsEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        poolKeyHash.hash(into: &hasher)
        if let p = try? params.toPrimitive() { p.hash(into: &hasher) }
    }
}

/// Stake pool parameters for a set of pools.
///
/// Returned by `GetStakePoolParams` (query tag 17).
public struct StakePoolParams: CBORSerializable, Sendable {
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
            let hash: Data
            switch key {
            case .bytes(let d): hash = d
            case .byteArray(let b): hash = Data(b)
            default:
                throw LedgerStateDecodingError.unexpectedFormat("StakePoolParams: expected bytes for pool key hash")
            }
            let params = try PoolParams(from: value)
            return StakePoolParamsEntry(poolKeyHash: hash, params: params)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var dict: [(Primitive, Primitive)] = []
        for entry in entries {
            dict.append((.bytes(entry.poolKeyHash), try entry.params.toPrimitive()))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: dict))
    }

}
