import SwiftCardanoCore

/// The ledger account state: current treasury and reserves balances.
///
/// Returned by `GetAccountState` (query tag 29).
/// Wire format: `[treasury: uint, reserves: uint]`
public struct AccountState: Serializable {
    public let treasury: UInt64
    public let reserves: UInt64

    public init(treasury: UInt64, reserves: UInt64) {
        self.treasury = treasury
        self.reserves = reserves
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let elems) = primitive, elems.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat("AccountState: expected [treasury, reserves]")
        }
        treasury = try Self.uint(from: elems[0])
        reserves = try Self.uint(from: elems[1])
    }

    public func toPrimitive() throws -> Primitive {
        .list([.uint(UInt(treasury)), .uint(UInt(reserves))])
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default: throw LedgerStateDecodingError.unexpectedFormat("AccountState: expected uint")
        }
    }
}
