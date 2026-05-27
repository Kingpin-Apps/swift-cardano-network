import Foundation
import SwiftCardanoCore

/// Partial decode of the Conway `SnapShots`, contained in `CurrentEpochState`.
///
/// Wire format — 4-element array (older nodes):
/// ```
/// [stakeMark, stakeSet, stakeGo, fee]
/// ```
/// Wire format — 5-element array (newer nodes, adds mark pool distribution):
/// ```
/// [stakeMark, markPoolDistr, stakeSet, stakeGo, fee]
/// ```
///
/// The three `StakeSnapshot` blobs (mark / set / go) each contain a full copy of
/// stake, delegations, and pool parameters at that boundary.  `fee` (the `ssFee`
/// Lovelace reserve for the next epoch's reward calculation) is decoded as a
/// typed scalar.
public struct EpochSnapshots: Serializable {

    /// Lovelace reserved from fees for the upcoming epoch reward calculation (`ssFee`).
    public let fee: UInt64

    /// Mark stake snapshot — stake/delegations/pool-params at the epoch-roll mark boundary.
    public let stakeMark: StakeSnapshot

    /// Mark pool distribution (present in newer node versions; `nil` on older nodes).
    public let markPoolDistr: PoolDistr?

    /// Set stake snapshot — stake/delegations/pool-params at the set boundary.
    public let stakeSet: StakeSnapshot

    /// Go stake snapshot — the active snapshot used for reward and leader-schedule calculations.
    public let stakeGo: StakeSnapshot

    public init(
        fee: UInt64,
        stakeMark: StakeSnapshot = StakeSnapshot(),
        markPoolDistr: PoolDistr? = nil,
        stakeSet: StakeSnapshot = StakeSnapshot(),
        stakeGo: StakeSnapshot = StakeSnapshot()
    ) {
        self.fee           = fee
        self.stakeMark     = stakeMark
        self.markPoolDistr = markPoolDistr
        self.stakeSet      = stakeSet
        self.stakeGo       = stakeGo
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "EpochSnapshots: expected array of ≥4 elements [mark, (poolDistr,) set, go, fee]"
            )
        }
        // 5-element (newer): [mark, markPoolDistr, set, go, fee]
        // 4-element (older): [mark, set, go, fee]
        if f.count >= 5 {
            stakeMark     = try StakeSnapshot(from: f[0])
            markPoolDistr = try PoolDistr(from: f[1])
            stakeSet      = try StakeSnapshot(from: f[2])
            stakeGo       = try StakeSnapshot(from: f[3])
            fee           = try Self.decodeUInt(f[4])
        } else {
            stakeMark     = try StakeSnapshot(from: f[0])
            markPoolDistr = nil
            stakeSet      = try StakeSnapshot(from: f[1])
            stakeGo       = try StakeSnapshot(from: f[2])
            fee           = try Self.decodeUInt(f[3])
        }
    }

    public func toPrimitive() throws -> Primitive {
        if let poolDistr = markPoolDistr {
            return .list([
                try stakeMark.toPrimitive(),
                try poolDistr.toPrimitive(),
                try stakeSet.toPrimitive(),
                try stakeGo.toPrimitive(),
                .uint(UInt64(fee)),
            ])
        }
        return .list([
            try stakeMark.toPrimitive(),
            try stakeSet.toPrimitive(),
            try stakeGo.toPrimitive(),
            .uint(UInt64(fee)),
        ])
    }

    private static func decodeUInt(_ p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("EpochSnapshots: fee must be uint")
        }
    }
}

extension EpochSnapshots: Equatable {
    public static func == (lhs: EpochSnapshots, rhs: EpochSnapshots) -> Bool {
        lhs.fee == rhs.fee
            && lhs.stakeMark == rhs.stakeMark
            && lhs.markPoolDistr == rhs.markPoolDistr
            && lhs.stakeSet == rhs.stakeSet
            && lhs.stakeGo == rhs.stakeGo
    }
}

extension EpochSnapshots: Hashable {
    public func hash(into hasher: inout Hasher) {
        fee.hash(into: &hasher)
    }
}
