import Foundation
import SwiftCardanoCore

/// The set of registered stake pool IDs (28-byte key hashes).
///
/// Returned by `GetStakePools` (query tag 16).
/// Wire format: CBOR tag-258 set (or array) of 28-byte pool key hashes.
public struct StakePools: Serializable {
    /// Stake-pool operators (bech32 `pool…` IDs; underlying 28-byte key hashes).
    public let poolOperators: [PoolOperator]

    public init(poolOperators: [PoolOperator]) {
        self.poolOperators = poolOperators
    }

    public init(from primitive: Primitive) throws {
        var elements: [Primitive]
        switch primitive {
        case .list(let l):
            elements = l
        case .frozenList(let l):
            elements = l
        case .frozenSet(let s):
            elements = Array(s)
        case .cborTag(let tag):
            // Tag-258 semantic set — skip the tag and read the inner array
            if case .list(let l) = tag.value {
                elements = l
            } else {
                throw LedgerStateDecodingError.unexpectedFormat("StakePools: unexpected tag value")
            }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("StakePools: expected list or set, got \(primitive)")
        }
        poolOperators = try elements.map { try PoolOperator(from: $0) }
    }

    public func toPrimitive() throws -> Primitive {
        .list(try poolOperators.map { try $0.toPrimitive() })
    }

    public func hash(into hasher: inout Hasher) {
        poolOperators.hash(into: &hasher)
    }

    public static func == (lhs: StakePools, rhs: StakePools) -> Bool {
        lhs.poolOperators == rhs.poolOperators
    }
}
