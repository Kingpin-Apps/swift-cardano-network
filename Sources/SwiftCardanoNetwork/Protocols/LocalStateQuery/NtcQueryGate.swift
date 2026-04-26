// MARK: - NtcQueryGate
//
// Single source of truth for NtC version-conditional encoding of LocalStateQuery
// `BlockQuery` requests.  Mirrors `blockQueryIsSupportedOnVersion` from
// IntersectMBO/ouroboros-consensus.
//
// LAST VERIFIED: ouroboros-consensus main HEAD (2026-04-25)
//   Sources fetched directly from raw.githubusercontent.com:
//     ouroboros-consensus-cardano/src/shelley/Ouroboros/Consensus/Shelley/Ledger/Query.hs
//       (`blockQueryIsSupportedOnVersion` — every BlockQuery constructor's
//        ShelleyNodeToClientVersion gate)
//     ouroboros-consensus-cardano/src/ouroboros-consensus-cardano/Ouroboros/Consensus/Cardano/Node.hs
//       (`supportedNodeToClientVersions` — NtCv16..NtCv23 → CardanoNTCv12..19;
//        each CardanoNTCvN is built with ShelleyNodeToClientVersion(N-4))
//
// Field-tested against cardano-node 10.6.2 (NtCv22) on 2026-04-25.  The 10.6.2
// node was observed to be lenient about queries the gate predicts as removed
// (e.g. `GetStakeDistribution` tag 5 still returned a result at NtCv22) — the
// gate below follows upstream HEAD, which 10.7.0+ is expected to enforce
// strictly.
//
// NtC wire ↔ Shelley ledger NtC version mapping referenced below:
//   NtCv16 = ShelleyV8     NtCv20 = ShelleyV12
//   NtCv17 = ShelleyV9     NtCv21 = ShelleyV13
//   NtCv18 = ShelleyV10    NtCv22 = ShelleyV14   (cardano-node 10.6.0)
//   NtCv19 = ShelleyV11    NtCv23 = ShelleyV15   (cardano-node 10.7.0)

/// Static version-gating table for `BlockQuery` requests.
///
/// `NtcQueryGate` carries no state; every member is `static`.  Query factories
/// in `LedgerQuery+Typed.swift` consult it to choose the correct CBOR tag for
/// queries whose wire encoding changed across NtC versions and to refuse early
/// (with `LocalStateQueryError.queryNotSupported`) when a caller asks for a
/// query the negotiated version cannot service.
public enum NtcQueryGate {

    /// A `BlockQuery` constructor known to this library.
    ///
    /// Cases are named after the corresponding Swift factory on `LedgerQuery`
    /// where one exists, otherwise after the upstream Haskell constructor.
    /// The raw value is the CBOR query tag the encoder emits at versions
    /// where the gate predicts that tag (see `currentTag(at:)` for queries
    /// whose tag changes across versions).
    public enum QueryKind: Sendable, Hashable {
        // Always-on (any negotiated NtC version)
        case ledgerTip
        case epochNo
        case nonMyopicMemberRewards
        case currentProtocolParameters
        case utxoByAddress
        case utxoWhole
        case filteredDelegationsAndRewardAccounts
        case genesisConfig
        case rewardProvenance
        case utxoByTxIn
        case stakePools
        case stakePoolParams
        case rewardInfoPools
        case poolState
        case stakeSnapshots
        case stakeDelegDeposits

        // Removed at v20+
        case proposedProtocolParametersUpdates

        // Stake distribution / pool distribution: legacy tags 5/21 deprecated
        // at v21+, replaced with 37/36 respectively.  Callers ask for these
        // logical kinds; the gate picks the right tag.
        case stakeDistribution
        case poolDistr

        // Conway governance — added at v16
        case constitutionHash
        case governanceState
        case drepState
        case drepStakeDistr
        case committeeMembersState
        case filteredVoteDelegatees
        case accountState
        case spoStakeDistr

        // Added at v17
        case proposals
        case ratifyState

        // Added at v18
        case futurePParams

        // Added at v19; encoding changes at v23+
        case bigLedgerPeerSnapshot

        // Added at v20
        case stakePoolDefaultVote

        // Added at v21
        case getMaxMajorProtocolVersion

        // Added at v23
        case drepDelegations
    }

    /// Wire encoding for `bigLedgerPeerSnapshot` (tag 34).
    public enum BigLedgerPeerSnapshotEncoding: Sendable {
        /// Pre-v23 wire form: `[34]`
        case legacy
        /// v23+ wire form: `[34, peerKindByte]`
        case srv
    }

    // MARK: - Public API

    /// The lowest NtC wire version at which `kind` is supported.
    ///
    /// Used for `LocalStateQueryError.queryNotSupported.requiredVersion`.
    public static func minVersion(for kind: QueryKind) -> UInt16 {
        switch kind {
        case .ledgerTip, .epochNo, .nonMyopicMemberRewards, .currentProtocolParameters,
             .utxoByAddress, .utxoWhole, .filteredDelegationsAndRewardAccounts,
             .genesisConfig, .rewardProvenance, .utxoByTxIn, .stakePools, .stakePoolParams,
             .rewardInfoPools, .poolState, .stakeSnapshots, .stakeDelegDeposits,
             .proposedProtocolParametersUpdates, .stakeDistribution, .poolDistr:
            return NodeToClientVersion.v9

        case .constitutionHash, .governanceState, .drepState, .drepStakeDistr,
             .committeeMembersState, .filteredVoteDelegatees, .accountState, .spoStakeDistr:
            return NodeToClientVersion.v16

        case .proposals, .ratifyState:
            return NodeToClientVersion.v17

        case .futurePParams:
            return NodeToClientVersion.v18

        case .bigLedgerPeerSnapshot:
            return NodeToClientVersion.v19

        case .stakePoolDefaultVote:
            return NodeToClientVersion.v20

        case .getMaxMajorProtocolVersion:
            return NodeToClientVersion.v21

        case .drepDelegations:
            return NodeToClientVersion.v23
        }
    }

    /// The highest NtC wire version at which `kind` is supported, or `nil`
    /// if there is no known upper bound.
    public static func maxVersion(for kind: QueryKind) -> UInt16? {
        switch kind {
        case .proposedProtocolParametersUpdates:
            return NodeToClientVersion.v19
        case .stakeDistribution, .poolDistr:
            // Legacy tags 5/21 only.  At v21+ the gate emits the replacement
            // tags 37/36, so the logical query stays usable — but if a caller
            // explicitly asks for the legacy tag form, this is the cap.
            return NodeToClientVersion.v20
        default:
            return nil
        }
    }

    /// Whether `kind` is supported at the given negotiated NtC wire version.
    public static func isSupported(_ kind: QueryKind, at version: UInt16) -> Bool {
        guard version >= minVersion(for: kind) else { return false }
        if let max = maxVersion(for: kind), version > max { return false }
        return true
    }

    /// Human-readable name used in `queryNotSupported` errors.
    public static func name(_ kind: QueryKind) -> String {
        switch kind {
        case .ledgerTip:                            return "ledgerTip"
        case .epochNo:                              return "epochNo"
        case .nonMyopicMemberRewards:               return "nonMyopicMemberRewards"
        case .currentProtocolParameters:            return "currentProtocolParameters"
        case .utxoByAddress:                        return "utxoByAddress"
        case .utxoWhole:                            return "utxoWhole"
        case .filteredDelegationsAndRewardAccounts: return "filteredDelegationsAndRewardAccounts"
        case .genesisConfig:                        return "genesisConfig"
        case .rewardProvenance:                     return "rewardProvenance"
        case .utxoByTxIn:                           return "utxoByTxIn"
        case .stakePools:                           return "stakePools"
        case .stakePoolParams:                      return "stakePoolParams"
        case .rewardInfoPools:                      return "rewardInfoPools"
        case .poolState:                            return "poolState"
        case .stakeSnapshots:                       return "stakeSnapshots"
        case .stakeDelegDeposits:                   return "stakeDelegDeposits"
        case .proposedProtocolParametersUpdates:    return "proposedProtocolParametersUpdates"
        case .stakeDistribution:                    return "stakeDistribution"
        case .poolDistr:                            return "poolDistr"
        case .constitutionHash:                     return "constitutionHash"
        case .governanceState:                      return "governanceState"
        case .drepState:                            return "drepState"
        case .drepStakeDistr:                       return "drepStakeDistr"
        case .committeeMembersState:                return "committeeMembersState"
        case .filteredVoteDelegatees:               return "filteredVoteDelegatees"
        case .accountState:                         return "accountState"
        case .spoStakeDistr:                        return "spoStakeDistr"
        case .proposals:                            return "proposals"
        case .ratifyState:                          return "ratifyState"
        case .futurePParams:                        return "futurePParams"
        case .bigLedgerPeerSnapshot:                return "bigLedgerPeerSnapshot"
        case .stakePoolDefaultVote:                 return "stakePoolDefaultVote"
        case .getMaxMajorProtocolVersion:           return "getMaxMajorProtocolVersion"
        case .drepDelegations:                      return "drepDelegations"
        }
    }

    // MARK: - Tag selection helpers

    /// CBOR tag the encoder should emit for `stakeDistribution` at `version`.
    ///
    /// - Returns: `5` for v9..v20 (legacy `GetStakeDistribution`), `37` for
    ///   v21+ (replacement `GetStakeDistribution2`).
    public static func tagForStakeDistribution(at version: UInt16) -> UInt64 {
        version >= NodeToClientVersion.v21 ? 37 : 5
    }

    /// CBOR tag the encoder should emit for `poolDistr` at `version`.
    ///
    /// - Returns: `21` for v9..v20 (legacy `GetPoolDistr`), `36` for v21+
    ///   (replacement `GetPoolDistr2`).
    public static func tagForPoolDistr(at version: UInt16) -> UInt64 {
        version >= NodeToClientVersion.v21 ? 36 : 21
    }

    /// Wire encoding for `bigLedgerPeerSnapshot` at `version`.
    ///
    /// - Returns: `.legacy` for v19..v22 (`[34]`), `.srv` for v23+
    ///   (`[34, peerKindByte]`).
    public static func bigLedgerPeerSnapshotEncoding(at version: UInt16) -> BigLedgerPeerSnapshotEncoding {
        version >= NodeToClientVersion.v23 ? .srv : .legacy
    }
}
