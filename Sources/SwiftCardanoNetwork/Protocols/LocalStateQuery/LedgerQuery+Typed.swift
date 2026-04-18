import NIOCore
import SwiftCardanoCore

// MARK: - Typed LedgerQuery constructors
//
// Each factory method builds the era-tagged CBOR query payload that
// LocalStateQueryCodec expects in RawQuery.rawCBOR, then wraps it in
// LedgerQuery.raw(_:).  The existing codec, driver, and client are
// completely unchanged; only the query construction is new here.
//
// Query tag reference (pallas / Ouroboros mini-protocol spec, Conway era):
//   GetLedgerTip                            = 0
//   GetEpochNo                              = 1
//   GetCurrentPParams                       = 3
//   GetProposedPParamsUpdates               = 4
//   GetStakeDistribution                    = 5
//   GetUTxOByAddress                        = 6   (+ Tag-258 set of addr bstrs)
//   GetFilteredDelegationAndRewardAccounts  = 10  (+ Tag-258 set of credentials)
//   GetGenesisConfig                        = 11
//   GetUTxOByTxIn                           = 15  (+ Tag-258 set of tx inputs)
//   GetStakePoolParams                      = 17  (+ Tag-258 set of pool keys)
//   GetGovState                             = 24
//   GetConstitution                         = 23
//   GetRatifyState                          = 32

extension LedgerQuery {

    // MARK: - Simple (no-parameter) queries

    /// Query the current ledger tip (slot + block hash).
    public static var ledgerTip: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 0)))
    }

    /// Query the current epoch number.
    public static var epochNo: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 1)))
    }

    /// Query the current protocol parameters.
    public static var currentProtocolParameters: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 3)))
    }

    /// Query any proposed (but not yet enacted) protocol parameter updates.
    public static var proposedProtocolParametersUpdates: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 4)))
    }

    /// Query the stake distribution across stake pools.
    public static var stakeDistribution: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 5)))
    }

    /// Query the genesis configuration for the current era.
    public static var genesisConfig: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 11)))
    }

    /// Query the current Conway governance state.
    public static var governanceState: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 24)))
    }

    /// Query the current constitution hash.
    public static var constitutionHash: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 23)))
    }

    /// Query the current ratification state (Conway governance).
    public static var ratifyState: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 32)))
    }

    // MARK: - Parameterised queries

    /// Query the UTxO set filtered to the given addresses.
    ///
    /// Addresses are encoded as CBOR byte strings inside a Tag-258 set, matching
    /// the Ouroboros `GetUTxOByAddress` wire format.
    public static func utxoByAddress(_ addresses: [Address]) -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + addresses.count * 64)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(6, into: &buf)
        writeTag258Set(count: addresses.count, into: &buf)
        for address in addresses {
            CBORLite.writeByteString(Array(address.toBytes()), into: &buf)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query the UTxO set filtered to the given transaction inputs.
    ///
    /// Inputs are CBOR-encoded as `[txId, index]` arrays inside a Tag-258 set,
    /// matching the Ouroboros `GetUTxOByTxIn` wire format.
    public static func utxoByTxIn(_ inputs: [TransactionInput]) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + inputs.count * 40)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(15, into: &buf)
        writeTag258Set(count: inputs.count, into: &buf)
        for input in inputs {
            let data = try input.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query stake pool parameters for the given pool operators.
    public static func stakePoolParams(_ pools: [PoolOperator]) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + pools.count * 32)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(17, into: &buf)
        writeTag258Set(count: pools.count, into: &buf)
        for pool in pools {
            let data = try pool.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query filtered delegations and reward account summaries for the given stake credentials.
    public static func filteredDelegationsAndRewardAccounts(
        _ credentials: [any Credential]
    ) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + credentials.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(10, into: &buf)
        writeTag258Set(count: credentials.count, into: &buf)
        for cred in credentials {
            let credData = try cred.toCBORData(deterministic: true)
            buf.writeBytes(credData)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }
}

// MARK: - Private helpers

private func simpleQueryBuf(tag: UInt64) -> ByteBuffer {
    var buf = ByteBufferAllocator().buffer(capacity: 4)
    CBORLite.writeArrayHeader(count: 1, into: &buf)
    CBORLite.writeUInt(tag, into: &buf)
    return buf
}

/// Write a CBOR Tag 258 (semantic set) header followed by an array header.
/// The caller is responsible for writing `count` CBOR values immediately after.
private func writeTag258Set(count: Int, into buf: inout ByteBuffer) {
    CBORLite.writeTag(258, into: &buf)
    CBORLite.writeArrayHeader(count: count, into: &buf)
}

// MARK: - Era helper

private extension Era {
    /// The UInt16 era number used in the LocalStateQuery era-tagged wire format.
    /// Matches the Cardano era numbering: Byron=0, Shelley=1, …, Conway=6.
    var rawQueryEra: UInt16 {
        switch self {
        case .byron:   return 0
        case .shelley: return 1
        case .allegra: return 2
        case .mary:    return 3
        case .alonzo:  return 4
        case .babbage: return 5
        case .conway:  return 6
        }
    }
}
