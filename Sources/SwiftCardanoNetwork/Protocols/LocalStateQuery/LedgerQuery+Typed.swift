import NIOCore
import SwiftCardanoCore

// MARK: - Typed LedgerQuery constructors
//
// Each factory builds the era-tagged CBOR query payload that
// `LocalStateQueryCodec` expects, wrapped in `LedgerQuery.raw(_:)`.  Every
// factory takes `at: UInt16` — the negotiated NtC wire version — so it can:
//   1. refuse early (`LocalStateQueryError.queryNotSupported`) when the
//      requested query is outside the upstream `blockQueryIsSupportedOnVersion`
//      gate for that version;
//   2. (in subsequent commits) emit the correct CBOR tag for queries whose
//      wire form changed across versions, e.g. `stakeDistribution` 5 → 37 at
//      NtCv21+.
//
// The `at:` parameter defaults to `NodeToClientVersion.v16` so direct callers
// and tests that don't go through `NodeToClientConnection` still build queries
// for the Conway-era stable surface.  `LocalStateQueryClient`'s typed wrappers
// always pass `negotiatedVersion`.  When `at == 0` (the LocalStateQueryClient
// no-handshake default) gate checks are skipped — the caller is trusted.
//
// Query tag reference (Conway era, current upstream HEAD):
//   GetLedgerTip                            = 0
//   GetEpochNo                              = 1
//   GetNonMyopicMemberRewards               = 2   (+ Tag-258 set)
//   GetCurrentPParams                       = 3
//   GetProposedPParamsUpdates               = 4   (removed at NtCv20+)
//   GetStakeDistribution                    = 5   (removed at NtCv21+; emit tag 37)
//   GetUTxOByAddress                        = 6
//   GetUTxOWhole                            = 7
//   GetFilteredDelegationAndRewardAccounts  = 10
//   GetGenesisConfig                        = 11
//   GetRewardProvenance                     = 14
//   GetUTxOByTxIn                           = 15
//   GetStakePools                           = 16
//   GetStakePoolParams                      = 17
//   GetRewardInfoPools                      = 18
//   GetPoolState                            = 19
//   GetStakeSnapshots                       = 20
//   GetPoolDistr                            = 21  (removed at NtCv21+; emit tag 36)
//   GetStakeDelegDeposits                   = 22
//   GetConstitution                         = 23  (NtCv16+)
//   GetGovState                             = 24  (NtCv16+)
//   GetDRepState                            = 25  (NtCv16+)
//   GetDRepStakeDistr                       = 26  (NtCv16+)
//   GetCommitteeMembersState                = 27  (NtCv16+)
//   GetFilteredVoteDelegatees               = 28  (NtCv16+)
//   GetAccountState                         = 29  (NtCv16+)
//   GetSPOStakeDistr                        = 30  (NtCv16+)
//   GetProposals                            = 31  (NtCv17+)
//   GetRatifyState                          = 32  (NtCv17+)
//   GetFuturePParams                        = 33  (NtCv18+)
//   GetBigLedgerPeerSnapshot                = 34  (NtCv19+; SRV form at NtCv23+)

extension LedgerQuery {

    // MARK: - Always-on queries (no version gating; never throw)

    /// Query the current ledger tip (slot + block hash).
    public static func ledgerTip(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 0)))
    }

    /// Query the current epoch number.
    public static func epochNo(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 1)))
    }

    /// Query the current protocol parameters.
    public static func currentProtocolParameters(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 3)))
    }

    /// Query the complete UTxO set (all unspent outputs in the ledger).
    ///
    /// - Warning: This can be a very large response on mainnet. Prefer
    ///   `utxoByAddress` or `utxoByTxIn` for targeted queries.
    public static func utxoWhole(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 7)))
    }

    /// Query the genesis configuration for the current era.
    public static func genesisConfig(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 11)))
    }

    /// Query detailed reward provenance data for the current epoch.
    public static func rewardProvenance(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 14)))
    }

    /// Query the set of all registered stake pool IDs.
    public static func stakePools(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 16)))
    }

    /// Query per-pool reward information for the current epoch.
    public static func rewardInfoPools(at version: UInt16 = NodeToClientVersion.v16) -> LedgerQuery {
        .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 18)))
    }

    // MARK: - Version-gated queries (may throw queryNotSupported)

    /// Query any proposed (but not yet enacted) protocol parameter updates.
    ///
    /// Available at NtC v9..v19; removed from NtCv20+ upstream.
    public static func proposedProtocolParametersUpdates(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.proposedProtocolParametersUpdates, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 4)))
    }

    /// Query the stake distribution across stake pools.
    ///
    /// Wire form is version-conditional: tag 5 at NtCv9..v20, tag 37 at
    /// NtCv21+ (upstream replaced `GetStakeDistribution` with
    /// `GetStakeDistribution2` from ShelleyV13).  Picked automatically by
    /// `NtcQueryGate.tagForStakeDistribution(at:)`.
    public static func stakeDistribution(
        at version: UInt16 = NodeToClientVersion.v16
    ) -> LedgerQuery {
        let tag = NtcQueryGate.tagForStakeDistribution(at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: tag)))
    }

    /// Query the current constitution hash.
    public static func constitutionHash(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.constitutionHash, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 23)))
    }

    /// Query the current Conway governance state.
    public static func governanceState(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.governanceState, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 24)))
    }

    /// Query the current account state (treasury and reserves).
    public static func accountState(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.accountState, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 29)))
    }

    /// Query the current ratification state (Conway governance).
    public static func ratifyState(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.ratifyState, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 32)))
    }

    /// Query the future protocol parameters (post-ratification, pre-epoch-boundary).
    public static func futurePParams(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.futurePParams, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 33)))
    }

    /// Query the big ledger peer snapshot for use in peer bootstrapping.
    ///
    /// Wire form at NtCv19..v22: bare `[34]`.  At NtCv23+ the encoder must
    /// switch to the SRV form `[34, peerKindByte]` — handled in a follow-up
    /// commit.
    public static func bigLedgerPeerSnapshot(
        at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.bigLedgerPeerSnapshot, at: version)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: simpleQueryBuf(tag: 34)))
    }

    // MARK: - Parameterised queries

    /// Query the UTxO set filtered to the given addresses.
    public static func utxoByAddress(
        _ addresses: [Address], at version: UInt16 = NodeToClientVersion.v16
    ) -> LedgerQuery {
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
    public static func utxoByTxIn(
        _ inputs: [TransactionInput], at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
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
    public static func stakePoolParams(
        _ pools: [PoolOperator], at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
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
        _ credentials: [any Credential], at version: UInt16 = NodeToClientVersion.v16
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
    public static func nonMyopicMemberRewards(
        _ inputs: [NonMyopicMemberRewardsInput], at version: UInt16 = NodeToClientVersion.v16
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
    public static func poolState(
        _ pools: [PoolOperator]?, at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
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
    public static func stakeSnapshots(
        _ pool: PoolOperator?, at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
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
    /// Wire form is version-conditional: tag 21 at NtCv9..v20, tag 36 at
    /// NtCv21+ (upstream replaced `GetPoolDistr` with `GetPoolDistr2` from
    /// ShelleyV13).  Picked automatically by
    /// `NtcQueryGate.tagForPoolDistr(at:)`.
    public static func poolDistr(
        _ pools: [PoolOperator]?, at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        let tag = NtcQueryGate.tagForPoolDistr(at: version)
        if let pools {
            var buf = ByteBufferAllocator().buffer(capacity: 32 + pools.count * 32)
            CBORLite.writeArrayHeader(count: 2, into: &buf)
            CBORLite.writeUInt(tag, into: &buf)
            CBORLite.writeArrayHeader(count: 1, into: &buf)
            writeTag258Set(count: pools.count, into: &buf)
            for pool in pools {
                let data = try pool.toCBORData(deterministic: true)
                buf.writeBytes(data)
            }
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
        } else {
            return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: maybeNothingQueryBuf(tag: tag)))
        }
    }

    /// Query stake delegation deposits for the given stake credentials.
    public static func stakeDelegDeposits(
        _ credentials: [any Credential], at version: UInt16 = NodeToClientVersion.v16
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
    public static func drepState(
        _ dreps: [DRep], at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.drepState, at: version)
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
    public static func drepStakeDistr(
        _ dreps: [DRep], at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.drepStakeDistr, at: version)
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
    public static func committeeMembersState(
        _ filter: CommitteeMembersFilter, at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.committeeMembersState, at: version)
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
        writeTag258Set(count: 0, into: &buf)
        return .raw(RawQuery(era: Era.conway.rawQueryEra, rawCBOR: buf))
    }

    /// Query the DRep each stake credential has delegated their vote to.
    public static func filteredVoteDelegatees(
        _ credentials: [any Credential], at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.filteredVoteDelegatees, at: version)
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
    public static func spoStakeDistr(
        _ pools: [PoolOperator]?, at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.spoStakeDistr, at: version)
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
    public static func proposals(
        _ govActionIDs: [GovActionID], at version: UInt16 = NodeToClientVersion.v16
    ) throws -> LedgerQuery {
        try gateCheck(.proposals, at: version)
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

/// Throws `LocalStateQueryError.queryNotSupported` if the query isn't allowed
/// at the negotiated version.  Skipped when `version == 0` (no handshake
/// information available — caller is trusted).
private func gateCheck(_ kind: NtcQueryGate.QueryKind, at version: UInt16) throws {
    guard version != 0 else { return }
    guard NtcQueryGate.isSupported(kind, at: version) else {
        throw LocalStateQueryError.queryNotSupported(
            name: NtcQueryGate.name(kind),
            negotiatedVersion: version,
            requiredVersion: NtcQueryGate.minVersion(for: kind)
        )
    }
}

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
