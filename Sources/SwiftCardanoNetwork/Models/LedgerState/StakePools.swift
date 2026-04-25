import Foundation
import SwiftCardanoCore

/// The set of registered stake pool IDs (28-byte key hashes).
///
/// Returned by `GetStakePools` (query tag 16).
/// Wire format: CBOR tag-258 set (or array) of 28-byte pool key hashes.
public struct StakePools: CBORSerializable, Sendable {
    /// Raw 28-byte pool key hashes.
    public let poolKeyHashes: [Data]

    public init(poolKeyHashes: [Data]) {
        self.poolKeyHashes = poolKeyHashes
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
        poolKeyHashes = try elements.map { elem -> Data in
            switch elem {
            case .bytes(let d): return d
            case .byteArray(let b): return Data(b)
            default:
                throw LedgerStateDecodingError.unexpectedFormat("StakePools: expected bytes for pool key hash")
            }
        }
    }

    public func toPrimitive() throws -> Primitive {
        .list(poolKeyHashes.map { .bytes($0) })
    }

    public func hash(into hasher: inout Hasher) {
        poolKeyHashes.hash(into: &hasher)
    }

    public static func == (lhs: StakePools, rhs: StakePools) -> Bool {
        lhs.poolKeyHashes == rhs.poolKeyHashes
    }
}
