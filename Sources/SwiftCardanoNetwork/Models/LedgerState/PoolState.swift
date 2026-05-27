import Foundation
import OrderedCollections
import SwiftCardanoCore

/// The state for a single stake pool.
public struct PoolStateEntry: Serializable {
    /// Stake-pool operator (bech32 `pool…` ID; underlying 28-byte key hash).
    public let poolOperator: PoolOperator
    /// Current registered pool parameters.
    public let poolParams: PoolParams
    /// Pending pool parameter update queued for the next epoch, if any.
    public let futurePoolParams: PoolParams?
    /// Pool deposit amount in lovelace (typically 500₳).
    public let deposit: UInt64
    /// Epoch at which this pool will retire, if it has filed retirement.
    public let retiring: UInt64?

    public init(
        poolOperator: PoolOperator,
        poolParams: PoolParams,
        futurePoolParams: PoolParams?,
        deposit: UInt64,
        retiring: UInt64?
    ) {
        self.poolOperator = poolOperator
        self.poolParams = poolParams
        self.futurePoolParams = futurePoolParams
        self.deposit = deposit
        self.retiring = retiring
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolStateEntry: expected [poolOperator, poolParams, futureParams?, deposit, retiring?]")
        }
        poolOperator     = try PoolOperator(from: f[0])
        poolParams       = try PoolParams(from: f[1])
        futurePoolParams = (try? PoolParams(from: f[2]))
        switch f[3] {
        case .uint(let u):              deposit = UInt64(u)
        case .int(let i) where i >= 0:  deposit = UInt64(i)
        default:                        deposit = 0
        }
        if f.count >= 5 {
            switch f[4] {
            case .uint(let u):              retiring = UInt64(u)
            case .int(let i) where i >= 0:  retiring = UInt64(i)
            default:                        retiring = nil
            }
        } else {
            retiring = nil
        }
    }

    public func toPrimitive() throws -> Primitive {
        var out: [Primitive] = [
            try poolOperator.toPrimitive(),
            try poolParams.toPrimitive(),
            (try futurePoolParams?.toPrimitive()) ?? .null,
            .uint(UInt64(deposit)),
        ]
        if let r = retiring { out.append(.uint(UInt64(r))) }
        return .list(out)
    }

    public func toDict() throws -> Primitive {
        var dict = OrderedDictionary<Primitive, Primitive>()
        dict[.string("poolOperator")] = try poolOperator.toDict()
        dict[.string("poolParams")]   = try poolParams.toPrimitive()
        if let f = futurePoolParams {
            dict[.string("futurePoolParams")] = try f.toPrimitive()
        }
        dict[.string("deposit")] = .uint(UInt64(deposit))
        if let r = retiring { dict[.string("retiring")] = .uint(UInt64(r)) }
        return .orderedDict(dict)
    }
}

extension PoolStateEntry {
    public static func == (lhs: PoolStateEntry, rhs: PoolStateEntry) -> Bool {
        guard
            let lp = try? lhs.poolParams.toPrimitive(),
            let rp = try? rhs.poolParams.toPrimitive()
        else { return false }
        let futureEq: Bool = {
            switch (lhs.futurePoolParams, rhs.futurePoolParams) {
            case (nil, nil): return true
            case (let l?, let r?):
                guard let lf = try? l.toPrimitive(), let rf = try? r.toPrimitive() else { return false }
                return lf == rf
            default: return false
            }
        }()
        return lhs.poolOperator == rhs.poolOperator
            && lp == rp
            && futureEq
            && lhs.deposit == rhs.deposit
            && lhs.retiring == rhs.retiring
    }

    public func hash(into hasher: inout Hasher) {
        poolOperator.hash(into: &hasher)
        if let p = try? poolParams.toPrimitive() { p.hash(into: &hasher) }
        deposit.hash(into: &hasher)
        retiring.hash(into: &hasher)
    }
}

/// Per-pool state including parameters, deposits, and optional retirement epoch.
///
/// Returned by `GetPoolState` (query tag 19).
///
/// Wire format: a CBOR list of four maps `[currentParams, futureParams, retiring, deposits]`:
/// - `currentParams`: `{ pool_key_hash → PoolParams }` — registered parameters
/// - `futureParams`: `{ pool_key_hash → PoolParams }` — pending updates queued for next epoch
/// - `retiring`: `{ pool_key_hash → epochNo }` — pools with filed retirement
/// - `deposits`: `{ pool_key_hash → coin }` — pool deposit balances
///
/// Entries are derived from the `currentParams` map and enriched from the other maps.
public struct PoolState: Serializable {
    public let entries: [PoolStateEntry]

    public init(entries: [PoolStateEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let outer) = primitive, outer.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "PoolState: expected [currentParams, futureParams, retiring, deposits]"
            )
        }

        let current = try Self.parsePoolParamsMap(outer[0], label: "currentParams")
        let future = try Self.parsePoolParamsMap(outer[1], label: "futureParams")
        let retiring = try Self.parseEpochMap(outer[2], label: "retiring")
        let deposits = try Self.parseEpochMap(outer[3], label: "deposits")

        entries = current.map { (hash, params) in
            let op = PoolOperator(poolKeyHash: PoolKeyHash(payload: hash))
            return PoolStateEntry(
                poolOperator: op,
                poolParams: params,
                futurePoolParams: future[hash],
                deposit: deposits[hash] ?? 0,
                retiring: retiring[hash]
            )
        }
    }

    public func toPrimitive() throws -> Primitive {
        var current: [(Primitive, Primitive)] = []
        var future: [(Primitive, Primitive)] = []
        var retiring: [(Primitive, Primitive)] = []
        var deposits: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = try entry.poolOperator.toPrimitive()
            current.append((key, try entry.poolParams.toPrimitive()))
            if let f = entry.futurePoolParams {
                future.append((key, try f.toPrimitive()))
            }
            if let r = entry.retiring {
                retiring.append((key, .uint(UInt64(r))))
            }
            deposits.append((key, .uint(UInt64(entry.deposit))))
        }
        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: current)),
            .frozenDict(Dictionary(uniqueKeysWithValues: future)),
            .frozenDict(Dictionary(uniqueKeysWithValues: retiring)),
            .frozenDict(Dictionary(uniqueKeysWithValues: deposits)),
        ])
    }

    public static func == (lhs: PoolState, rhs: PoolState) -> Bool {
        lhs.entries == rhs.entries
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    private static func parsePoolParamsMap(
        _ primitive: Primitive,
        label: String
    ) throws -> [Data: PoolParams] {
        let pairs = try mapPairs(primitive, label: label)
        var out: [Data: PoolParams] = [:]
        for (key, value) in pairs {
            out[try bytesKey(key, label: label)] = try PoolParams(from: value)
        }
        return out
    }

    private static func parseEpochMap(
        _ primitive: Primitive,
        label: String
    ) throws -> [Data: UInt64] {
        let pairs = try mapPairs(primitive, label: label)
        var out: [Data: UInt64] = [:]
        for (key, value) in pairs {
            out[try bytesKey(key, label: label)] = try uintValue(value, label: label)
        }
        return out
    }

    private static func mapPairs(
        _ primitive: Primitive,
        label: String
    ) throws -> [(Primitive, Primitive)] {
        switch primitive {
        case .dict(let d): return Array(d)
        case .orderedDict(let d): return d.map { ($0.key, $0.value) }
        case .frozenDict(let d): return Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolState: expected map for \(label)")
        }
    }

    private static func bytesKey(_ p: Primitive, label: String) throws -> Data {
        switch p {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolState: expected bytes key in \(label)")
        }
    }

    private static func uintValue(_ p: Primitive, label: String) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("PoolState: expected uint in \(label)")
        }
    }
}
