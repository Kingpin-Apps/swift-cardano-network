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
//   GetNonMyopicMemberRewards               = 2   (+ Tag-258 set of coin | credential inputs)
//   GetCurrentPParams                       = 3
//   GetProposedPParamsUpdates               = 4
//   GetStakeDistribution                    = 5
//   GetUTxOByAddress                        = 6   (+ Tag-258 set of addr bstrs)
//   GetUTxOWhole                            = 7
//   GetFilteredDelegationAndRewardAccounts  = 10  (+ Tag-258 set of credentials)
//   GetGenesisConfig                        = 11
//   GetRewardProvenance                     = 14
//   GetUTxOByTxIn                           = 15  (+ Tag-258 set of tx inputs)
//   GetStakePools                           = 16
//   GetStakePoolParams                      = 17  (+ Tag-258 set of pool keys)
//   GetRewardInfoPools                      = 18
//   GetPoolState                            = 19  (+ optional Tag-258 set of pool keys)
//   GetStakeSnapshots                       = 20  (+ optional pool key hash)
//   GetPoolDistr                            = 21  (+ optional Tag-258 set of pool keys)
//   GetStakeDelegDeposits                   = 22  (+ Tag-258 set of stake credentials)
//   GetConstitution                         = 23
//   GetGovState                             = 24
//   GetDRepState                            = 25  (+ Tag-258 set of DRep credentials)
//   GetDRepStakeDistr                       = 26  (+ Tag-258 set of DRep credentials)
//   GetCommitteeMembersState                = 27  (+ cold cred set, hot cred set, status set)
//   GetFilteredVoteDelegatees               = 28  (+ Tag-258 set of stake credentials)
//   GetAccountState                         = 29
//   GetSPOStakeDistr                        = 30  (+ optional Tag-258 set of pool keys)
//   GetProposals                            = 31  (+ Tag-258 set of GovActionIDs)
//   GetRatifyState                          = 32
//   GetFuturePParams                        = 33
//   GetBigLedgerPeerSnapshot                = 34

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

    /// Query the complete UTxO set (all unspent outputs in the ledger).
    ///
    /// - Warning: This can be a very large response on mainnet. Prefer
    ///   `utxoByAddress` or `utxoByTxIn` for targeted queries.
    public static var utxoWhole: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 7)))
    }

    /// Query the genesis configuration for the current era.
    public static var genesisConfig: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 11)))
    }

    /// Query detailed reward provenance data for the current epoch.
    public static var rewardProvenance: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 14)))
    }

    /// Query the set of all registered stake pool IDs.
    public static var stakePools: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 16)))
    }

    /// Query per-pool reward information for the current epoch.
    public static var rewardInfoPools: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 18)))
    }

    /// Query the current Conway governance state.
    public static var governanceState: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 24)))
    }

    /// Query the current constitution hash.
    public static var constitutionHash: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 23)))
    }

    /// Query the current account state (treasury and reserves).
    public static var accountState: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 29)))
    }

    /// Query the current ratification state (Conway governance).
    public static var ratifyState: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 32)))
    }

    /// Query the future protocol parameters (post-ratification, pre-epoch-boundary).
    public static var futurePParams: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 33)))
    }

    /// Query the big ledger peer snapshot for use in peer bootstrapping.
    public static var bigLedgerPeerSnapshot: LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 34)))
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

    /// Query projected non-myopic member rewards for the given inputs.
    ///
    /// Each input is either a coin amount (hypothetical stake) or a stake credential
    /// (existing account). The node returns projected rewards per pool for each input.
    public static func nonMyopicMemberRewards(
        _ inputs: [NonMyopicMemberRewardsInput]
    ) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + inputs.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(2, into: &buf)
        writeTag258Set(count: inputs.count, into: &buf)
        for input in inputs {
            switch input {
            case .coin(let v):
                CBORLite.writeUInt(v, into: &buf)
            case .credential(let cred):
                let data = try cred.toPrimitive().toCBORData(deterministic: true)
                buf.writeBytes(data)
            }
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query stake pool state for the given pools; pass `nil` to query all pools.
    ///
    /// `Maybe (Set PoolId)` encodes Nothing as `[]` and Just as `[tag258set]`.
    public static func poolState(_ pools: [PoolOperator]?) throws -> LedgerQuery {
        if let pools {
            var buf = ByteBufferAllocator().buffer(capacity: 32 + pools.count * 32)
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(19, into: &buf)
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            writeTag258Set(count: pools.count, into: &buf)
            for pool in pools {
                let data = try pool.toCBORData(deterministic: true)
                buf.writeBytes(data)
            }
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
        } else {
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: maybeNothingQueryBuf(tag: 19)))
        }
    }

    /// Query stake snapshots (mark/set/go) for a specific pool; pass `nil` for all pools.
    ///
    /// `Maybe PoolId` encodes Nothing as `[]` and Just as `[pool_bytes]`.
    public static func stakeSnapshots(_ pool: PoolOperator?) throws -> LedgerQuery {
        if let pool {
            let poolData = try pool.toCBORData(deterministic: true)
            var buf = ByteBufferAllocator().buffer(capacity: 32 + poolData.count)
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(20, into: &buf)
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            buf.writeBytes(poolData)
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
        } else {
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: maybeNothingQueryBuf(tag: 20)))
        }
    }

    /// Query pool stake distribution for the given pools; pass `nil` to query all pools.
    ///
    /// `Maybe (Set PoolId)` encodes Nothing as `[]` and Just as `[tag258set]`.
    public static func poolDistr(_ pools: [PoolOperator]?) throws -> LedgerQuery {
        if let pools {
            var buf = ByteBufferAllocator().buffer(capacity: 32 + pools.count * 32)
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(21, into: &buf)
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            writeTag258Set(count: pools.count, into: &buf)
            for pool in pools {
                let data = try pool.toCBORData(deterministic: true)
                buf.writeBytes(data)
            }
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
        } else {
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: maybeNothingQueryBuf(tag: 21)))
        }
    }

    /// Query stake delegation deposits for the given stake credentials.
    public static func stakeDelegDeposits(
        _ credentials: [any Credential]
    ) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + credentials.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(22, into: &buf)
        writeTag258Set(count: credentials.count, into: &buf)
        for cred in credentials {
            let data = try cred.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query on-chain state for the given DReps.
    public static func drepState(_ dreps: [DRep]) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + dreps.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(25, into: &buf)
        writeTag258Set(count: dreps.count, into: &buf)
        for drep in dreps {
            let data = try drep.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query total delegated stake for the given DReps.
    public static func drepStakeDistr(_ dreps: [DRep]) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + dreps.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(26, into: &buf)
        writeTag258Set(count: dreps.count, into: &buf)
        for drep in dreps {
            let data = try drep.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query current constitutional committee member states with optional filters.
    ///
    /// Empty filter sets (`CommitteeMembersFilter.all`) return all members.
    /// The query encodes three Tag-258 sets: cold credentials, hot credentials, and statuses.
    public static func committeeMembersState(
        _ filter: CommitteeMembersFilter
    ) throws -> LedgerQuery {
        let cold = filter.coldCredentials ?? []
        let hot = filter.hotCredentials ?? []
        var buf = ByteBufferAllocator().buffer(capacity: 64 + (cold.count + hot.count) * 36)
        CBORLite.writeArrayHeader(count: 4, into: &buf)
        CBORLite.writeUInt(27, into: &buf)
        writeTag258Set(count: cold.count, into: &buf)
        for cred in cold {
            let data = try cred.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        writeTag258Set(count: hot.count, into: &buf)
        for cred in hot {
            let data = try cred.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        // Empty status filter set (no status filter applied)
        writeTag258Set(count: 0, into: &buf)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query the DRep each stake credential has delegated their vote to.
    public static func filteredVoteDelegatees(
        _ credentials: [any Credential]
    ) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + credentials.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(28, into: &buf)
        writeTag258Set(count: credentials.count, into: &buf)
        for cred in credentials {
            let data = try cred.toCBORData(deterministic: true)
            buf.writeBytes(data)
        }
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query SPO stake distribution for the given pools; pass `nil` to query all pools.
    ///
    /// `Maybe (Set PoolId)` encodes Nothing as `[]` and Just as `[tag258set]`.
    public static func spoStakeDistr(_ pools: [PoolOperator]?) throws -> LedgerQuery {
        if let pools {
            var buf = ByteBufferAllocator().buffer(capacity: 32 + pools.count * 32)
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(30, into: &buf)
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            writeTag258Set(count: pools.count, into: &buf)
            for pool in pools {
                let data = try pool.toCBORData(deterministic: true)
                buf.writeBytes(data)
            }
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
        } else {
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: maybeNothingQueryBuf(tag: 30)))
        }
    }

    /// Query the active governance proposals matching the given governance action IDs.
    public static func proposals(_ govActionIDs: [GovActionID]) throws -> LedgerQuery {
        var buf = ByteBufferAllocator().buffer(capacity: 32 + govActionIDs.count * 36)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(31, into: &buf)
        writeTag258Set(count: govActionIDs.count, into: &buf)
        for id in govActionIDs {
            let data = try id.toCBORData(deterministic: true)
            buf.writeBytes(data)
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

/// Build a 2-element query `[tag, []]` for a `Maybe`-parameterised query where the
/// argument is `Nothing`.  In Haskell's cborg, `toCBOR Nothing = encodeListLen 0`,
/// so the Nothing case is an empty CBOR array, NOT the absence of the field.
private func maybeNothingQueryBuf(tag: UInt64) -> ByteBuffer {
    var buf = ByteBufferAllocator().buffer(capacity: 6)
    CBORLite.writeArrayHeader(count: 2, into: &buf)
    CBORLite.writeUInt(tag, into: &buf)
    CBORLite.writeArrayHeader(count: 0, into: &buf)
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
