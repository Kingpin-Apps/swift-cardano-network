import Foundation
import SwiftCardanoCore

/// A single entry mapping a DRep to its total delegated stake.
public struct DRepStakeEntry: Sendable {
    /// The DRep this entry belongs to.
    public let drep: DRep
    /// Total stake delegated to this DRep, in lovelace.
    public let stake: UInt64

    public init(drep: DRep, stake: UInt64) {
        self.drep = drep
        self.stake = stake
    }
}

extension DRepStakeEntry: Equatable {
    public static func == (lhs: DRepStakeEntry, rhs: DRepStakeEntry) -> Bool {
        (try? lhs.drep.toPrimitive()) == (try? rhs.drep.toPrimitive()) && lhs.stake == rhs.stake
    }
}

extension DRepStakeEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? drep.toPrimitive() { p.hash(into: &hasher) }
        stake.hash(into: &hasher)
    }
}

/// Map of DReps to their total delegated stake.
///
/// Returned by `GetDRepStakeDistr` (query tag 26).
/// Wire format: `{ drep_credential → coin }`
public struct DRepStakeDistribution: CBORSerializable, Sendable {
    public let entries: [DRepStakeEntry]

    public init(entries: [DRepStakeEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepStakeDistribution: expected map")
        }
        entries = try pairs.map { (key, value) in
            let drep = try DRep(from: key)
            let stake = try Self.uint(from: value)
            return DRepStakeEntry(drep: drep, stake: stake)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = try entry.drep.toPrimitive()
            pairs.append((key, .uint(UInt(entry.stake))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: DRepStakeDistribution, rhs: DRepStakeDistribution) -> Bool {
        lhs.entries == rhs.entries
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepStakeDistribution: expected uint for stake")
        }
    }
}
