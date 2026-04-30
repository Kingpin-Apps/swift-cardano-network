import SwiftCardanoCore

/// The full ledger epoch state, returned by `GetCBOR(DebugEpochState)` (tag 8).
///
/// Wire format: a CBOR byte string (from the `GetCBOR` wrapper) whose payload
/// is a 4-element array:
/// ```
/// [accountState, ledgerState, snapshots, nonMyopic]
/// ```
public struct CurrentEpochState: Serializable {

    /// Treasury and reserves balances.
    public let accountState: AccountState

    /// Ledger state — UTxO set, deposits, fees, governance state, and certificate state.
    public let ledgerState: EpochLedgerState

    /// Stake snapshots (mark / set / go) and the fee reserve for the next epoch.
    public let snapshots: EpochSnapshots

    /// Non-myopic rewards state — reward pot and per-pool likelihood arrays.
    public let nonMyopic: NonMyopicState

    public init(
        accountState: AccountState,
        ledgerState: EpochLedgerState,
        snapshots: EpochSnapshots,
        nonMyopic: NonMyopicState
    ) {
        self.accountState = accountState
        self.ledgerState  = ledgerState
        self.snapshots    = snapshots
        self.nonMyopic    = nonMyopic
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "CurrentEpochState: expected [accountState, ledgerState, snapshots, nonMyopic]"
            )
        }
        accountState = try AccountState(from: f[0])
        ledgerState  = try EpochLedgerState(from: f[1])
        snapshots    = try EpochSnapshots(from: f[2])
        nonMyopic    = try NonMyopicState(from: f[3])
    }

    public func toPrimitive() throws -> Primitive {
        .list([
            try accountState.toPrimitive(),
            try ledgerState.toPrimitive(),
            try snapshots.toPrimitive(),
            try nonMyopic.toPrimitive(),
        ])
    }
}

extension CurrentEpochState: Equatable {
    public static func == (lhs: CurrentEpochState, rhs: CurrentEpochState) -> Bool {
        guard let la = try? lhs.accountState.toPrimitive(),
              let ra = try? rhs.accountState.toPrimitive() else { return false }
        return la == ra
            && lhs.ledgerState == rhs.ledgerState
            && lhs.snapshots == rhs.snapshots
            && lhs.nonMyopic == rhs.nonMyopic
    }
}

extension CurrentEpochState: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? accountState.toPrimitive() { p.hash(into: &hasher) }
        ledgerState.hash(into: &hasher)
    }
}
