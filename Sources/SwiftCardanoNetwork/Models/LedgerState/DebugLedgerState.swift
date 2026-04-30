import Foundation
import OrderedCollections
import SwiftCardanoCore

// MARK: - PulsingRewUpdate

/// An in-progress or completed epoch reward update.
///
/// Wire format: a CBOR list `[tag, value]`:
///   - `[0, pulserData]` = Pulsing — mid-epoch incremental reward computation (opaque)
///   - `[1, updateData]` = Complete — fully computed reward update (opaque)
///
/// The StrictMaybe wrapper (`[]` = Nothing, `[value]` = Just) is handled by
/// `DebugLedgerState` — this type represents only the inner value.
public enum PulsingRewUpdate: Serializable {
    /// Mid-epoch incremental reward computation (opaque internal ledger state).
    case pulsing(Primitive)
    /// Fully computed reward update ready to apply at the epoch boundary (opaque).
    case complete(Primitive)

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PulsingRewUpdate: expected [tag, value], got \(primitive)")
        }
        let tag: UInt64
        switch f[0] {
        case .uint(let u): tag = UInt64(u)
        case .int(let i) where i >= 0: tag = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "PulsingRewUpdate: expected uint tag, got \(f[0])")
        }
        switch tag {
        case 0: self = .pulsing(f[1])
        case 1: self = .complete(f[1])
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "PulsingRewUpdate: unknown tag \(tag)")
        }
    }

    public func toPrimitive() throws -> Primitive {
        switch self {
        case .pulsing(let p):  return .list([.uint(0), p])
        case .complete(let p): return .list([.uint(1), p])
        }
    }

    /// Tagged JSON object so the variant is visible in description output.
    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        switch self {
        case .pulsing(let p):  dict[.string("pulsing")]  = p
        case .complete(let p): dict[.string("complete")] = p
        }
        return .orderedDict(dict)
    }
}

// MARK: - DebugLedgerState

/// The full new-epoch state, returned by `GetCBOR(DebugNewEpochState)` (tag 12).
///
/// Wire format: a CBOR byte string (from the `GetCBOR` wrapper) whose payload
/// is a 7-element array:
/// ```
/// [epochNo, blocksMadePrev, blocksMadeCurr, epochState,
///  pulsingRewUpdate, poolDistribution, stashedAvvmAddresses]
/// ```
///
/// `epochNo`, `blocksMadePrev`, `blocksMadeCurr`, and `epochState` are fully
/// decoded.  The remaining three fields are kept as opaque `Primitive` blobs
/// because `pulsingRewUpdate` is an internal ledger computation structure and
/// `poolDistribution` is more efficiently accessed via `queryPoolDistr`.
public struct DebugLedgerState: Serializable {

    /// Current epoch number.
    public let epochNo: UInt64

    /// Pool issuer key hash → block count for the previous epoch.
    public let blocksMadePrev: [Data: UInt64]

    /// Pool issuer key hash → block count for the current (in-progress) epoch.
    public let blocksMadeCurr: [Data: UInt64]

    /// Full epoch state (treasury, ledger, snapshots, non-myopic rewards).
    public let epochState: CurrentEpochState

    /// Pulsing reward update state (`StrictMaybe (PulsingRewUpdate era)`).
    ///
    /// `nil` when no reward update is in progress (most of the epoch after the
    /// boundary has settled).  Non-nil mid-epoch or at the epoch boundary.
    public let pulsingRewUpdate: PulsingRewUpdate?

    /// Stake distribution across all registered pools for the current epoch.
    ///
    /// Equivalent to `queryPoolDistr()` but bundled inside the full new-epoch state.
    /// Wire format: `[{ pool_key_hash → [tag-30([num, denom]), lovelace, vrf_hash] }, totalActiveStake]`
    public let poolDistribution: PoolDistr

    public init(
        epochNo: UInt64,
        blocksMadePrev: [Data: UInt64],
        blocksMadeCurr: [Data: UInt64],
        epochState: CurrentEpochState,
        pulsingRewUpdate: PulsingRewUpdate?,
        poolDistribution: PoolDistr
    ) {
        self.epochNo          = epochNo
        self.blocksMadePrev   = blocksMadePrev
        self.blocksMadeCurr   = blocksMadeCurr
        self.epochState       = epochState
        self.pulsingRewUpdate = pulsingRewUpdate
        self.poolDistribution = poolDistribution
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 6 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "DebugLedgerState: expected [epochNo, bprev, bcurr, epochState, rewUpd, poolDistr, ...]"
            )
        }
        epochNo          = try Self.decodeEpochNo(f[0])
        blocksMadePrev   = try Self.decodeBlocksMade(f[1])
        blocksMadeCurr   = try Self.decodeBlocksMade(f[2])
        epochState       = try CurrentEpochState(from: f[3])
        pulsingRewUpdate = try Self.decodeStrictMaybePulsingRewUpdate(f[4])
        poolDistribution = try PoolDistr(from: f[5])
    }

    public func toPrimitive() throws -> Primitive {
        let rewUpdatePrim: Primitive
        if let upd = pulsingRewUpdate {
            rewUpdatePrim = .list([try upd.toPrimitive()])
        } else {
            rewUpdatePrim = .list([])
        }
        return .list([
            .uint(UInt(epochNo)),
            try Self.encodeBlocksMade(blocksMadePrev),
            try Self.encodeBlocksMade(blocksMadeCurr),
            try epochState.toPrimitive(),
            rewUpdatePrim,
            try poolDistribution.toPrimitive(),
        ])
    }

    /// Produce a labeled JSON object instead of the wire-format positional list.
    ///
    /// The default Mirror-based `toDict()` can't represent `pulsingRewUpdate` because
    /// `PulsingRewUpdate` doesn't conform to `CBORSerializable`, so it falls back to
    /// `toPrimitive()` and prints as a JSON array. Override here so the description
    /// stays a labeled JSON object like the other typed query results.
    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("epochNo")]          = .uint(UInt(epochNo))
        dict[.string("blocksMadePrev")]   = try Self.encodeBlocksMade(blocksMadePrev)
        dict[.string("blocksMadeCurr")]   = try Self.encodeBlocksMade(blocksMadeCurr)
        dict[.string("epochState")]       = try epochState.toDict()
        dict[.string("pulsingRewUpdate")] = try pulsingRewUpdate.map { try $0.toDict() } ?? .null
        dict[.string("poolDistribution")] = try poolDistribution.toDict()
        return .orderedDict(dict)
    }

    // MARK: - Private helpers

    private static func decodeEpochNo(_ p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "DebugLedgerState: epochNo must be uint"
            )
        }
    }

    /// Decode `StrictMaybe (PulsingRewUpdate)`: `[]` = Nothing, `[inner]` = Just(inner).
    private static func decodeStrictMaybePulsingRewUpdate(_ p: Primitive) throws -> PulsingRewUpdate? {
        guard case .list(let items) = p else { return nil }
        guard let first = items.first else { return nil }
        return try PulsingRewUpdate(from: first)
    }

    /// Decode a `BlocksMade` value: CBOR map `{ pool_issuer_key_hash → block_count }`.
    private static func decodeBlocksMade(_ p: Primitive) throws -> [Data: UInt64] {
        let pairs: [(Primitive, Primitive)]
        switch p {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "DebugLedgerState: BlocksMade must be a CBOR map"
            )
        }
        var out: [Data: UInt64] = [:]
        out.reserveCapacity(pairs.count)
        for (k, v) in pairs {
            let keyBytes: Data
            switch k {
            case .bytes(let d):      keyBytes = d
            case .byteArray(let b):  keyBytes = Data(b)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "DebugLedgerState: BlocksMade key must be bytes"
                )
            }
            switch v {
            case .uint(let n):            out[keyBytes] = UInt64(n)
            case .int(let n) where n >= 0: out[keyBytes] = UInt64(n)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "DebugLedgerState: BlocksMade value must be uint"
                )
            }
        }
        return out
    }

    private static func encodeBlocksMade(_ m: [Data: UInt64]) throws -> Primitive {
        var dict: [(Primitive, Primitive)] = []
        dict.reserveCapacity(m.count)
        for (k, v) in m {
            dict.append((.bytes(k), .uint(UInt(v))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: dict))
    }
}

extension DebugLedgerState: Equatable {
    public static func == (lhs: DebugLedgerState, rhs: DebugLedgerState) -> Bool {
        lhs.epochNo == rhs.epochNo
            && lhs.blocksMadePrev == rhs.blocksMadePrev
            && lhs.blocksMadeCurr == rhs.blocksMadeCurr
            && lhs.epochState == rhs.epochState
            && lhs.pulsingRewUpdate == rhs.pulsingRewUpdate
            && lhs.poolDistribution == rhs.poolDistribution
    }
}

extension DebugLedgerState: Hashable {
    public func hash(into hasher: inout Hasher) {
        epochNo.hash(into: &hasher)
        epochState.hash(into: &hasher)
    }
}
