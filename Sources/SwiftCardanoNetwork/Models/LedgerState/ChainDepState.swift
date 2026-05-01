import Foundation
import SwiftCardanoCore

/// The consensus protocol state, returned by `GetCBOR(DebugChainDepState)` (tag 13).
///
/// Wire format (live node, Conway era — `encodeListLen 8` from
/// `ouroboros-consensus-protocol/Ouroboros/Consensus/Protocol/Praos.hs`):
/// ```
/// [0, [lastSlot, ocertCounters, evolvingNonce, candidateNonce, epochNonce,
///      previousEpochNonce, labNonce, lastEpochBlockNonce]]
/// ```
/// The outer `[0, …]` is a HardFork era-constructor wrapper.  The inner array is
/// `PraosState`.  Field ordering varies across node versions — live Conway nodes
/// place `ocertCounters` at index 1 (after `lastSlot`), whereas the Haskell
/// SERIALISE reference order puts nonces before counters.  The decoder scans for
/// the counters map by key/value type so it is position-agnostic.
///
/// `WithOrigin SlotNo` wire encoding:
///   - `Origin` → `[0]`  (or `[]` in test / hand-crafted CBOR)
///   - `At slot` → `[1, slot]`
///
/// `Nonce` wire encoding (cardano-ledger `EncCBOR Nonce`):
///   - `NeutralNonce` → `[0]`        (CBOR list-len 1, tag 0)
///   - `Nonce h`      → `[1, h]`     (CBOR list-len 2, tag 1, 32-byte Blake2b-256 hash)
///
/// Legacy / hand-crafted CBOR (still accepted by the decoder for backwards
/// compatibility with existing tests):
///   - `NeutralNonce` → CBOR `null`
///   - `Nonce h`      → CBOR `bytes(32)`
public struct ChainDepState: Serializable {

    /// Per-pool operational certificate counters.
    ///
    /// Key: pool operator (`PoolOperator`, Blake2b-224 key hash).
    /// Value: current OCert sequence number (incremented on each new cert).
    public let operationalCertCounters: [PoolOperator: UInt64]

    /// Slot number of the last block processed by consensus, if any.
    public let lastSlot: UInt64?

    // MARK: - Nonces

    /// VRF evolving nonce — updated on every block.  `nil` = NeutralNonce.
    public let evolvingNonce: Data?

    /// VRF candidate nonce — candidate for the upcoming epoch nonce.  `nil` = NeutralNonce.
    public let candidateNonce: Data?

    /// Epoch nonce — fixed at the epoch boundary; seeds VRF leader checks.  `nil` = NeutralNonce.
    public let epochNonce: Data?

    /// Previous epoch nonce — the prior epoch's `epochNonce`, retained for
    /// rollback windows that span an epoch boundary.  `nil` = NeutralNonce.
    public let previousEpochNonce: Data?

    /// Look-ahead-buffer nonce — derived from the hash of the previous block.
    /// `nil` = NeutralNonce.
    public let labNonce: Data?

    /// Nonce corresponding to the LAB nonce of the last block of the previous
    /// epoch.  Seeds the next epoch's `epochNonce`.  `nil` = NeutralNonce.
    public let lastEpochBlockNonce: Data?

    /// Extra fields beyond the named nonces (forward-compatibility padding).
    public let rawExtraFields: [Primitive]

    public init(
        operationalCertCounters: [PoolOperator: UInt64],
        lastSlot: UInt64?,
        evolvingNonce: Data? = nil,
        candidateNonce: Data? = nil,
        epochNonce: Data? = nil,
        previousEpochNonce: Data? = nil,
        labNonce: Data? = nil,
        lastEpochBlockNonce: Data? = nil,
        rawExtraFields: [Primitive] = []
    ) {
        self.operationalCertCounters = operationalCertCounters
        self.lastSlot                = lastSlot
        self.evolvingNonce           = evolvingNonce
        self.candidateNonce          = candidateNonce
        self.epochNonce              = epochNonce
        self.previousEpochNonce      = previousEpochNonce
        self.labNonce                = labNonce
        self.lastEpochBlockNonce     = lastEpochBlockNonce
        self.rawExtraFields          = rawExtraFields
    }

    public init(from primitive: Primitive) throws {
        // Peel the HardFork era-constructor wrapper [tag, state] if present.
        let state = Self.peelWrapper(primitive)
        guard case .list(let f) = state, f.count >= 7 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "ChainDepState: expected PraosState array of ≥7 elements, got \(state)"
            )
        }

        lastSlot = try? Self.decodeWithOriginSlot(f[0])

        // Locate ocertCounters by scanning for the CBOR map whose keys are 28-byte
        // byte strings (pool issuer key hashes, Blake2b-224) and whose values are uints.
        // This is robust to field-ordering changes across node versions.
        guard let (ocertIdx, counters) = Self.locateOCertCounters(in: f) else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "ChainDepState: no ocertCounters map found in \(f.count)-element PraosState"
            )
        }
        operationalCertCounters = counters

        // Collect remaining elements (excluding lastSlot at 0 and ocertCounters at ocertIdx)
        // in their original order.  Haskell field order after last slot and ocert counters
        // (from cardano-protocol-tpraos `Serialise PraosState`):
        //   evolvingNonce, candidateNonce, epochNonce,
        //   previousEpochNonce, labNonce, lastEpochBlockNonce.
        let remaining = f.indices.compactMap { i in (i == 0 || i == ocertIdx) ? nil : f[i] }
        evolvingNonce       = remaining.count > 0 ? Self.decodeNonce(remaining[0]) : nil
        candidateNonce      = remaining.count > 1 ? Self.decodeNonce(remaining[1]) : nil
        epochNonce          = remaining.count > 2 ? Self.decodeNonce(remaining[2]) : nil
        previousEpochNonce  = remaining.count > 3 ? Self.decodeNonce(remaining[3]) : nil
        labNonce            = remaining.count > 4 ? Self.decodeNonce(remaining[4]) : nil
        lastEpochBlockNonce = remaining.count > 5 ? Self.decodeNonce(remaining[5]) : nil
        rawExtraFields      = remaining.count > 6 ? Array(remaining[6...]) : []
    }

    public func toPrimitive() throws -> Primitive {
        var elems: [Primitive] = []
        // WithOrigin SlotNo: Origin = [0], At slot = [1, slot]
        if let slot = lastSlot {
            elems.append(.list([.uint(1), .uint(UInt(slot))]))
        } else {
            elems.append(.list([.uint(0)]))
        }
        // ocertCounters is written first (live Conway position, index 1) so a
        // round-trip produces the same shape the live node sends.  Nonces follow
        // in cardano-protocol-tpraos `Serialise PraosState` field order.
        elems.append(try Self.encodeOCertCounters(operationalCertCounters))
        elems.append(Self.encodeNonce(evolvingNonce))
        elems.append(Self.encodeNonce(candidateNonce))
        elems.append(Self.encodeNonce(epochNonce))
        elems.append(Self.encodeNonce(previousEpochNonce))
        elems.append(Self.encodeNonce(labNonce))
        elems.append(Self.encodeNonce(lastEpochBlockNonce))
        elems.append(contentsOf: rawExtraFields)
        return .list(elems)
    }

    // MARK: - Private helpers

    /// Strip a HardFork era-constructor wrapper `[uint, payload]` if present.
    private static func peelWrapper(_ p: Primitive) -> Primitive {
        guard case .list(let f) = p,
              f.count == 2,
              case .list(_) = f[1] else { return p }
        switch f[0] {
        case .uint(_), .int(_): return f[1]
        default: return p
        }
    }

    /// Decode a Haskell `WithOrigin SlotNo`.
    ///
    /// Wire (Conway node): `Origin` = `[0]`, `At slot` = `[1, slot]`.
    /// Legacy / test CBOR: `Origin` = `[]`, `At slot` = `[slot]`.
    private static func decodeWithOriginSlot(_ p: Primitive) throws -> UInt64? {
        switch p {
        case .list(let elems):
            guard !elems.isEmpty else { return nil }   // [] = Origin (legacy)
            switch elems[0] {
            case .uint(0), .int(0): return nil         // [0] = Origin
            case .uint(1), .int(1):                    // [1, slot] = At(slot)
                guard elems.count >= 2 else { return nil }
                switch elems[1] {
                case .uint(let v): return UInt64(v)
                case .int(let v) where v >= 0: return UInt64(v)
                default: return nil
                }
            case .uint(let v): return UInt64(v)        // [slot] = At(slot) (legacy)
            case .int(let v) where v >= 0: return UInt64(v)
            default: return nil
            }
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default: return nil
        }
    }

    /// Decode a `Nonce`.
    ///
    /// Live wire format (cardano-ledger `EncCBOR Nonce`):
    ///   - `[0]`        → `nil` (NeutralNonce)
    ///   - `[1, bytes32]` → `Data` (Nonce h)
    ///
    /// Legacy forms still accepted:
    ///   - CBOR `null`   → `nil`
    ///   - `bytes(32)`   → `Data`
    private static func decodeNonce(_ p: Primitive) -> Data? {
        switch p {
        case .null:                                    return nil
        case .bytes(let d) where d.count == 32:        return d
        case .byteArray(let b) where b.count == 32:    return Data(b)
        case .list(let elems):
            guard let first = elems.first else { return nil }
            switch first {
            case .uint(0), .int(0):
                return nil                              // [0] = NeutralNonce
            case .uint(1), .int(1):
                guard elems.count >= 2 else { return nil }
                switch elems[1] {
                case .bytes(let d)     where d.count == 32: return d
                case .byteArray(let b) where b.count == 32: return Data(b)
                default: return nil
                }
            default: return nil
            }
        default: return nil
        }
    }

    /// Encode a `Nonce` in the live wire format used by cardano-ledger:
    /// `nil` → `[0]`, `Data` → `[1, bytes32]`.
    private static func encodeNonce(_ nonce: Data?) -> Primitive {
        guard let d = nonce else { return .list([.uint(0)]) }
        return .list([.uint(1), .bytes(d)])
    }

    /// Scan `f[1...]` for a CBOR map whose first key is a 28-byte byte string and
    /// whose values are uints — that is `praosStateOCertCounters` regardless of
    /// which field index the node places it at.
    private static func locateOCertCounters(in f: [Primitive]) -> (index: Int, [PoolOperator: UInt64])? {
        for i in 1..<f.count {
            let pairs: [(Primitive, Primitive)]
            switch f[i] {
            case .dict(let d):        pairs = Array(d)
            case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
            case .frozenDict(let d):  pairs = Array(d)
            default: continue
            }

            // Non-empty map: verify first key is a 28-byte byte string (pool key hash)
            // AND first value is a uint (OCert sequence number).
            // This distinguishes ocertCounters from hashesBefore (whose values are hashes).
            if !pairs.isEmpty {
                let (firstKey, firstVal) = pairs[0]
                switch firstKey {
                case .bytes(let d)     where d.count == 28: break
                case .byteArray(let b) where b.count == 28: break
                default: continue
                }
                switch firstVal {
                case .uint(_), .int(_): break
                default: continue
                }
            }

            // Decode all pairs.
            var out: [PoolOperator: UInt64] = [:]
            out.reserveCapacity(pairs.count)
            var allDecoded = true
            for (k, v) in pairs {
                let keyBytes: Data? = {
                    switch k {
                    case .bytes(let d):     return d
                    case .byteArray(let b): return Data(b)
                    default:                return nil
                    }
                }()
                let counter: UInt64? = {
                    switch v {
                    case .uint(let n):             return UInt64(n)
                    case .int(let n) where n >= 0: return UInt64(n)
                    default:                       return nil
                    }
                }()
                guard let kb = keyBytes, let c = counter,
                      let op = try? PoolOperator(from: kb) else { allDecoded = false; break }
                out[op] = c
            }
            if allDecoded { return (i, out) }
        }
        return nil
    }

    private static func encodeOCertCounters(_ m: [PoolOperator: UInt64]) throws -> Primitive {
        var dict: [(Primitive, Primitive)] = []
        dict.reserveCapacity(m.count)
        for (k, v) in m {
            dict.append((try k.toPrimitive(), .uint(UInt(v))))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: dict))
    }
}

extension ChainDepState: Equatable {
    public static func == (lhs: ChainDepState, rhs: ChainDepState) -> Bool {
        lhs.operationalCertCounters == rhs.operationalCertCounters
            && lhs.lastSlot == rhs.lastSlot
            && lhs.evolvingNonce == rhs.evolvingNonce
            && lhs.candidateNonce == rhs.candidateNonce
            && lhs.epochNonce == rhs.epochNonce
            && lhs.previousEpochNonce == rhs.previousEpochNonce
            && lhs.labNonce == rhs.labNonce
            && lhs.lastEpochBlockNonce == rhs.lastEpochBlockNonce
    }
}

extension ChainDepState: Hashable {
    public func hash(into hasher: inout Hasher) {
        lastSlot.hash(into: &hasher)
        evolvingNonce.hash(into: &hasher)
        epochNonce.hash(into: &hasher)
        previousEpochNonce.hash(into: &hasher)
        lastEpochBlockNonce.hash(into: &hasher)
    }
}
