import Foundation
import NIOCore
import SwiftCardanoCore

// MARK: - RawResult decoding

extension RawResult {

    /// Decode the raw CBOR result into any `CBORSerializable` type from SwiftCardanoCore.
    ///
    /// ```swift
    /// let params = try result.decode(ProtocolParameters.self)
    /// ```
    public func decode<T: CBORSerializable>(_ type: T.Type) throws -> T {
        let data = Data(rawCBOR.readableBytesView)
        return try T.fromCBOR(data: data)
    }

    /// Decode the raw CBOR result as a CBOR-map–encoded UTxO set.
    ///
    /// The Ouroboros node returns UTxO query results as a CBOR map:
    /// `{ TransactionInput → TransactionOutput }`.
    /// This helper iterates the map and assembles `[UTxO]`.
    public func decodeUTxOs() throws -> [UTxO] {
        var buf = rawCBOR
        // The node may or may not wrap the map in an outer Tag; skip it if present.
        if CBORLite.peekMajorType(from: buf) == CBORLite.majorTag {
            _ = try CBORLite.readTag(from: &buf)
        }
        let pairCount = try CBORLite.readMapHeader(from: &buf)
        var utxos: [UTxO] = []
        utxos.reserveCapacity(pairCount)
        for _ in 0..<pairCount {
            let keyData = Data(try CBORLite.readValueBuffer(from: &buf).readableBytesView)
            let valueData = Data(try CBORLite.readValueBuffer(from: &buf).readableBytesView)
            let input = try TransactionInput.fromCBOR(data: keyData)
            let output = try TransactionOutput.fromCBOR(data: valueData)
            utxos.append(UTxO(input: input, output: output))
        }
        return utxos
    }
}

// MARK: - Typed query overloads

extension LocalStateQueryClient {

    // MARK: UTxO

    /// Query the UTxO set filtered to the given addresses.
    public func queryUTxO(for addresses: [Address]) async throws -> [UTxO] {
        let result = try await query(.utxoByAddress(addresses))
        return try result.decodeUTxOs()
    }

    /// Query the UTxO set filtered to the given transaction inputs.
    public func queryUTxO(for inputs: [TransactionInput]) async throws -> [UTxO] {
        let q = try LedgerQuery.utxoByTxIn(inputs)
        let result = try await query(q)
        return try result.decodeUTxOs()
    }

    /// Query the complete UTxO set (all unspent outputs in the ledger).
    ///
    /// - Warning: This can return a very large response on mainnet.
    public func queryWholeUTxO() async throws -> [UTxO] {
        let result = try await query(.utxoWhole)
        return try result.decodeUTxOs()
    }

    // MARK: Protocol parameters

    /// Query the current protocol parameters, decoded from the node's CBOR response.
    public func queryProtocolParameters() async throws -> ProtocolParameters {
        let result = try await query(.currentProtocolParameters)
        let data = Data(result.rawCBOR.readableBytesView)
        return try ProtocolParameters.fromCBOR(data: data)
    }

    /// Query the current protocol parameters, decoded from the node's CBOR response.
    public func queryProposedProtocolParametersUpdates() async throws -> ProposedProtocolParamUpdates {
        let result = try await query(.proposedProtocolParametersUpdates)
        let data = Data(result.rawCBOR.readableBytesView)
        return try ProposedProtocolParamUpdates.fromCBOR(data: data)
    }

    /// Query the future protocol parameters (post-ratification, pre-epoch-boundary).
    ///
    /// Returns `nil` when there are no pending future parameters (the node returns an
    /// empty CBOR list `[]` for `Nothing` in the `Maybe PParams` response).
    public func queryFuturePParams() async throws -> ProtocolParameters? {
        let result = try await query(.futurePParams)
        var buf = result.rawCBOR
        // Maybe PParams: [] = Nothing (no future params), [params] = Just params
        let count = try CBORLite.readArrayHeader(from: &buf)
        guard count == 1 else { return nil }
        let data = Data(try CBORLite.readValueBuffer(from: &buf).readableBytesView)
        return try ProtocolParameters.fromCBOR(data: data)
    }

    // MARK: Ledger tip

    /// Query the current ledger tip as a `Point`.
    ///
    /// The node returns a CBOR `[slot, hash]` pair; this decodes it using CBORLite
    /// and assembles the existing `Point` type (no new dependency on CardanoCore).
    public func queryLedgerTip() async throws -> Point {
        let result = try await query(.ledgerTip)
        var buf = result.rawCBOR
        let count = try CBORLite.readArrayHeader(from: &buf)
        guard count == 2 else {
            throw LocalStateQueryError.unexpectedArrayLength(count)
        }
        let slot = try CBORLite.readUInt(from: &buf)
        let hash = try CBORLite.readByteString(from: &buf)
        return .blockPoint(slot: slot, hash: hash)
    }

    // MARK: Epoch

    /// Query the current epoch number.
    public func queryEpochNo() async throws -> EpochNumber {
        let result = try await query(.epochNo)
        var buf = result.rawCBOR
        let epoch = try CBORLite.readUInt(from: &buf)
        return EpochNumber(epoch)
    }

    // MARK: Stake distribution

    /// Query the complete stake distribution for specific pools, or all pools if `nil`.
    public func queryPoolDistr(_ pools: [PoolOperator]? = nil) async throws -> PoolDistr {
        let q = try LedgerQuery.poolDistr(pools)
        let result = try await query(q)
        return try result.decode(PoolDistr.self)
    }

    // MARK: Stake pools

    /// Query the set of all registered stake pool IDs.
    public func queryStakePools() async throws -> StakePools {
        let result = try await query(.stakePools)
        return try result.decode(StakePools.self)
    }

    /// Query stake pool parameters for the given pool operators.
    public func queryStakePoolParams(for pools: [PoolOperator]) async throws -> StakePoolParams {
        let q = try LedgerQuery.stakePoolParams(pools)
        let result = try await query(q)
        return try result.decode(StakePoolParams.self)
    }

    /// Query per-pool state for the given pools, or all pools if `nil`.
    public func queryPoolState(_ pools: [PoolOperator]? = nil) async throws -> PoolState {
        let q = try LedgerQuery.poolState(pools)
        let result = try await query(q)
        return try result.decode(PoolState.self)
    }

    /// Query stake snapshots (mark/set/go) for a specific pool, or all pools if `nil`.
    public func queryStakeSnapshots(for pool: PoolOperator? = nil) async throws -> StakeSnapshots {
        let q = try LedgerQuery.stakeSnapshots(pool)
        let result = try await query(q)
        return try result.decode(StakeSnapshots.self)
    }

    /// Query the SPO stake distribution for the given pools, or all pools if `nil`.
    public func querySPOStakeDistr(_ pools: [PoolOperator]? = nil) async throws -> SPOStakeDistribution {
        let q = try LedgerQuery.spoStakeDistr(pools)
        let result = try await query(q)
        return try result.decode(SPOStakeDistribution.self)
    }

    // MARK: Rewards

    /// Query projected non-myopic member rewards for the given stake inputs.
    public func queryNonMyopicMemberRewards(
        _ inputs: [NonMyopicMemberRewardsInput]
    ) async throws -> NonMyopicMemberRewards {
        let q = try LedgerQuery.nonMyopicMemberRewards(inputs)
        let result = try await query(q)
        return try result.decode(NonMyopicMemberRewards.self)
    }

    /// Query per-pool reward information for the current epoch.
    public func queryRewardInfoPools() async throws -> RewardInfoPools {
        let result = try await query(.rewardInfoPools)
        return try result.decode(RewardInfoPools.self)
    }

    /// Query detailed reward provenance data for the current epoch.
    public func queryRewardProvenance() async throws -> RewardProvenance {
        let result = try await query(.rewardProvenance)
        return try result.decode(RewardProvenance.self)
    }

    // MARK: Delegations and deposits

    /// Query filtered delegations and reward account summaries for the given stake credentials.
    public func queryFilteredDelegationsAndRewardAccounts(
        _ credentials: [any Credential]
    ) async throws -> FilteredDelegationsAndRewards {
        let q = try LedgerQuery.filteredDelegationsAndRewardAccounts(credentials)
        let result = try await query(q)
        return try result.decode(FilteredDelegationsAndRewards.self)
    }

    /// Query stake delegation deposit amounts for the given stake credentials.
    public func queryStakeDelegDeposits(
        _ credentials: [any Credential]
    ) async throws -> StakeDelegDeposits {
        let q = try LedgerQuery.stakeDelegDeposits(credentials)
        let result = try await query(q)
        return try result.decode(StakeDelegDeposits.self)
    }

    // MARK: Governance (Conway)

    /// Query the current Conway governance state.
    public func queryGovernanceState() async throws -> GovernanceState {
        let result = try await query(.governanceState)
        return try result.decode(GovernanceState.self)
    }

    /// Query the current constitution.
    public func queryConstitution() async throws -> LedgerConstitution {
        let result = try await query(.constitutionHash)
        return try result.decode(LedgerConstitution.self)
    }

    /// Query the current ratification state.
    public func queryRatifyState() async throws -> RatifyState {
        let result = try await query(.ratifyState)
        return try result.decode(RatifyState.self)
    }

    /// Query the current account state (treasury and reserves).
    public func queryAccountState() async throws -> AccountState {
        let result = try await query(.accountState)
        return try result.decode(AccountState.self)
    }

    /// Query on-chain state for the given DReps.
    public func queryDRepState(_ dreps: [DRep]) async throws -> DRepState {
        let q = try LedgerQuery.drepState(dreps)
        let result = try await query(q)
        return try result.decode(DRepState.self)
    }

    /// Query total delegated stake for the given DReps.
    public func queryDRepStakeDistr(_ dreps: [DRep]) async throws -> DRepStakeDistribution {
        let q = try LedgerQuery.drepStakeDistr(dreps)
        let result = try await query(q)
        return try result.decode(DRepStakeDistribution.self)
    }

    /// Query constitutional committee member states with optional cold/hot credential filters.
    public func queryCommitteeMembersState(
        _ filter: CommitteeMembersFilter = .all
    ) async throws -> CommitteeMembersState {
        let q = try LedgerQuery.committeeMembersState(filter)
        let result = try await query(q)
        return try result.decode(CommitteeMembersState.self)
    }

    /// Query the DRep each stake credential has delegated their vote to.
    public func queryFilteredVoteDelegatees(
        _ credentials: [any Credential]
    ) async throws -> VoteDelegatees {
        let q = try LedgerQuery.filteredVoteDelegatees(credentials)
        let result = try await query(q)
        return try result.decode(VoteDelegatees.self)
    }

    /// Query active governance proposals matching the given governance action IDs.
    public func queryProposals(_ govActionIDs: [GovActionID]) async throws -> ActiveProposals {
        let q = try LedgerQuery.proposals(govActionIDs)
        let result = try await query(q)
        return try result.decode(ActiveProposals.self)
    }

    // MARK: Chain info

    /// Query the genesis configuration for the current era.
    public func queryGenesisConfig() async throws -> GenesisConfig {
        let result = try await query(.genesisConfig)
        return try result.decode(GenesisConfig.self)
    }

    /// Query the big ledger peer snapshot for peer bootstrapping.
    public func queryBigLedgerPeerSnapshot() async throws -> BigLedgerPeerSnapshot {
        let result = try await query(.bigLedgerPeerSnapshot)
        return try result.decode(BigLedgerPeerSnapshot.self)
    }
}
