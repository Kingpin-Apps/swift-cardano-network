import Foundation
import SwiftCardanoCore

/// Partial decode of the Conway `LedgerState`, contained in `CurrentEpochState`.
///
/// Wire format: a 2-element CBOR array `[utxoState, certState]`.
/// `utxoState` is itself a 5- or 6-element array:
/// ```
/// [ utxo, deposited, fees, govState, stakeDistr, donation? ]
/// ```
///
/// The UTxO map is kept opaque due to its size and era-dependent internal structure.
/// Use the targeted LSQ queries (`queryUTxO`, etc.) when you need specific UTxO data.
public struct EpochLedgerState: Serializable {

    // MARK: - UTxO state scalars

    /// Total Lovelace locked in protocol deposits.
    public let deposited: UInt64

    /// Fees accumulated in the UTxO state for the current epoch.
    public let fees: UInt64

    /// Treasury donation amount (Conway era; zero if not present).
    public let donation: UInt64

    // MARK: - Typed sub-structures

    /// Conway governance state (proposals, committee, constitution, protocol params, DRep state).
    /// `nil` on nodes that encode this as a non-governance-state value (e.g. pre-Conway ppups).
    public let govState: GovernanceState?

    /// Incremental stake distribution accumulated from UTxO entries within the current epoch.
    /// `nil` when the node encodes an empty or non-decodable value.
    public let stakeDistr: IncrementalStake?

    /// Certificate and delegation state (DState accounts, PState pool registrations, VState governance).
    /// `nil` when the node sends an incompatible or empty cert state (e.g. minimal test fixtures).
    public let certState: CertState?

    // MARK: - UTxO set

    /// Raw UTxO set, kept as `Primitive` to defer decoding.
    ///
    /// The wire format is a CBOR `Map TxIn TxOut` (optionally tagged).
    /// On preview/mainnet this set holds hundreds of thousands to millions of
    /// entries; eagerly materialising it into `[UTxO]` from `init(from:)` makes
    /// every `queryCurrentEpochState` / `queryDebugLedgerState` caller pay the
    /// full cost. Use `decodedUtxos()` only when you actually need the typed view.
    public let rawUtxo: Primitive

    /// Decode `rawUtxo` into typed `[UTxO]` entries on demand.
    ///
    /// - Warning: On preview/mainnet this can produce hundreds of thousands of
    ///   entries and is expensive in both time and memory. Equivalent in cost
    ///   to `cardano-cli query ledger-state`. Call only when the typed view is
    ///   actually needed.
    public func decodedUtxos() throws -> [UTxO] {
        var p = rawUtxo
        if case .cborTag(let t) = p { p = t.value }

        let pairs: [(Primitive, Primitive)]
        switch p {
        case .dict(let d):                 pairs = Array(d)
        case .orderedDict(let d):          pairs = d.map { ($0.key, $0.value) }
        case .indefiniteDictionary(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):           pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "EpochLedgerState.decodedUtxos: rawUtxo is not a CBOR map (got \(p))"
            )
        }

        var out: [UTxO] = []
        out.reserveCapacity(pairs.count)
        for (k, v) in pairs {
            let input  = try TransactionInput(from: k)
            let output = try TransactionOutput(from: v)
            out.append(UTxO(input: input, output: output))
        }
        return out
    }

    public init(
        deposited: UInt64 = 0,
        fees: UInt64 = 0,
        donation: UInt64 = 0,
        govState: GovernanceState? = nil,
        stakeDistr: IncrementalStake? = nil,
        certState: CertState? = nil,
        rawUtxo: Primitive = .dict([:])
    ) {
        self.deposited  = deposited
        self.fees       = fees
        self.donation   = donation
        self.govState   = govState
        self.stakeDistr = stakeDistr
        self.certState  = certState
        self.rawUtxo    = rawUtxo
    }

    public init(from primitive: Primitive) throws {
        // LedgerState = [UTxOState, CertState]
        guard case .list(let ls) = primitive, ls.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "EpochLedgerState: expected [utxoState, certState]"
            )
        }

        // UTxOState = [utxo, deposited, fees, govState, stakeDistr, donation?]
        guard case .list(let us) = ls[0], us.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "EpochLedgerState: expected UTxOState array of ≥3 elements"
            )
        }
        certState = ls.count > 1 ? (try? CertState(from: ls[1])) : nil
        rawUtxo   = us[0]
        deposited = (try? Self.decodeUInt(us[1], label: "deposited")) ?? 0
        fees      = (try? Self.decodeUInt(us[2], label: "fees")) ?? 0
        govState  = us.count > 3 ? (try? GovernanceState(from: us[3])) : nil
        stakeDistr = us.count > 4 ? (try? IncrementalStake(from: us[4])) : nil
        donation   = us.count > 5 ? (try? Self.decodeUInt(us[5], label: "donation")) ?? 0 : 0
    }

    public func toPrimitive() throws -> Primitive {
        let certPrimitive: Primitive
        if let cs = certState {
            certPrimitive = try cs.toPrimitive()
        } else {
            certPrimitive = .list([])
        }
        let utxoState = Primitive.list([
            rawUtxo,
            .uint(UInt(deposited)),
            .uint(UInt(fees)),
            try govState?.toPrimitive() ?? .list([]),
            try stakeDistr?.toPrimitive() ?? .list([]),
            .uint(UInt(donation)),
        ])
        return .list([utxoState, certPrimitive])
    }

    private static func decodeUInt(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "EpochLedgerState: \(label) must be uint"
            )
        }
    }
}

extension EpochLedgerState: Equatable {
    public static func == (lhs: EpochLedgerState, rhs: EpochLedgerState) -> Bool {
        lhs.deposited == rhs.deposited
            && lhs.fees == rhs.fees
            && lhs.donation == rhs.donation
            && lhs.rawUtxo == rhs.rawUtxo
            && lhs.govState == rhs.govState
            && lhs.stakeDistr == rhs.stakeDistr
            && lhs.certState == rhs.certState
    }
}

extension EpochLedgerState: Hashable {
    public func hash(into hasher: inout Hasher) {
        deposited.hash(into: &hasher)
        fees.hash(into: &hasher)
    }
}
