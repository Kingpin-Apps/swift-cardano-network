import Foundation
import SwiftCardanoCore

/// Partial decode of the Conway `NonMyopic` state, contained in `CurrentEpochState`.
///
/// Wire format: a 2-element CBOR array `[likelihoods, rewardPot]` where:
/// - `likelihoods` is a CBOR map `{ pool_key_hash → [Double] }` — per-pool likelihood weights
/// - `rewardPot` is a `Coin` (UInt64) representing the reward pot available for
///   non-myopic pool ranking
public struct NonMyopicState: Serializable {

    /// Lovelace pot available for non-myopic member reward projections (`rewardPotNM`).
    public let rewardPot: UInt64

    /// Per-pool likelihood weights used for non-myopic pool ranking.
    ///
    /// Maps pool key hash (28 bytes) to a list of probability weights.
    public let likelihoods: [Data: [Double]]

    public init(rewardPot: UInt64, likelihoods: [Data: [Double]] = [:]) {
        self.rewardPot    = rewardPot
        self.likelihoods  = likelihoods
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "NonMyopicState: expected [likelihoods, rewardPot]"
            )
        }
        likelihoods = try Self.decodeLikelihoods(f[0])
        rewardPot   = try Self.decodeUInt(f[1])
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for (hash, weights) in likelihoods {
            let weightsPrim = Primitive.list(weights.map { .float($0) })
            pairs.append((.bytes(hash), weightsPrim))
        }
        let likelDict: Primitive = pairs.isEmpty
            ? .dict([:])
            : .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
        return .list([likelDict, .uint(UInt64(rewardPot))])
    }

    private static func decodeLikelihoods(_ p: Primitive) throws -> [Data: [Double]] {
        let pairs: [(Primitive, Primitive)]
        switch p {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "NonMyopicState: likelihoods must be a CBOR map, got \(p)")
        }
        var out: [Data: [Double]] = [:]
        out.reserveCapacity(pairs.count)
        for (k, v) in pairs {
            let hash: Data
            switch k {
            case .bytes(let d):     hash = d
            case .byteArray(let b): hash = Data(b)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "NonMyopicState: likelihood key must be bytes")
            }
            let floats: [Primitive]
            switch v {
            case .list(let l):                 floats = l
            case .frozenList(let l):           floats = l
            case .indefiniteList(let l):       floats = Array(l)
            case .indefiniteFrozenList(let l): floats = Array(l)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "NonMyopicState: likelihood value must be a list, got \(v)")
            }
            let weights = try floats.map { try decodeDouble($0) }
            out[hash] = weights
        }
        return out
    }

    private static func decodeDouble(_ p: Primitive) throws -> Double {
        switch p {
        case .float(let d): return d
        case .uint(let u):  return Double(u)
        case .int(let i):   return Double(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "NonMyopicState: expected number in likelihoods list")
        }
    }

    private static func decodeUInt(_ p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "NonMyopicState: rewardPot must be uint"
            )
        }
    }
}

extension NonMyopicState: Equatable {
    public static func == (lhs: NonMyopicState, rhs: NonMyopicState) -> Bool {
        lhs.rewardPot == rhs.rewardPot && lhs.likelihoods == rhs.likelihoods
    }
}

extension NonMyopicState: Hashable {
    public func hash(into hasher: inout Hasher) {
        rewardPot.hash(into: &hasher)
    }
}
