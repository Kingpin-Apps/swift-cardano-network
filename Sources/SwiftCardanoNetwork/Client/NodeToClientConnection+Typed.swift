import NIOCore
import SwiftCardanoCore

// MARK: - NodeToClientConnection typed convenience API
//
// These methods are thin shorthands that delegate to the typed extensions on
// the individual mini-protocol clients.  Nothing in the existing
// NodeToClientConnection struct is modified; callers who do not import
// SwiftCardanoCore are completely unaffected.

extension NodeToClientConnection {

    // MARK: - UTxO

    /// Query the UTxO set filtered to the given addresses.
    public func queryUTxO(for addresses: [Address]) async throws -> [UTxO] {
        try await stateQuery.queryUTxO(for: addresses)
    }

    /// Query the UTxO set filtered to the given transaction inputs.
    public func queryUTxO(for inputs: [TransactionInput]) async throws -> [UTxO] {
        try await stateQuery.queryUTxO(for: inputs)
    }

    /// Query the complete UTxO set (all unspent outputs in the ledger).
    ///
    /// - Warning: This can return a very large response on mainnet.
    public func queryWholeUTxO() async throws -> [UTxO] {
        try await stateQuery.queryWholeUTxO()
    }

    // MARK: - Protocol parameters

    /// Query the current protocol parameters.
    public func queryProtocolParameters() async throws -> ProtocolParameters {
        try await stateQuery.queryProtocolParameters()
    }

    /// Query any proposed protocol parameter updates for the current epoch.
    public func queryProposedProtocolParametersUpdates() async throws -> ProposedProtocolParamUpdates {
        try await stateQuery.queryProposedProtocolParametersUpdates()
    }

    /// Query the future protocol parameters (post-ratification, pre-epoch-boundary).
    /// Returns `nil` when there are no pending future parameters.
    public func queryFuturePParams() async throws -> ProtocolParameters? {
        try await stateQuery.queryFuturePParams()
    }

    // MARK: - Ledger tip and epoch

    /// Query the current ledger tip as a `Point`.
    public func queryLedgerTip() async throws -> Point {
        try await stateQuery.queryLedgerTip()
    }

    /// Query the current epoch number.
    public func queryEpochNo() async throws -> EpochNumber {
        try await stateQuery.queryEpochNo()
    }

    // MARK: - Stake distribution

    /// Query the stake distribution for specific pools, or all pools if `nil`.
    public func queryPoolDistr(_ pools: [PoolOperator]? = nil) async throws -> PoolDistr {
        try await stateQuery.queryPoolDistr(pools)
    }

    // MARK: - Stake pools

    /// Query the set of all registered stake pool IDs.
    public func queryStakePools() async throws -> StakePools {
        try await stateQuery.queryStakePools()
    }

    /// Query stake pool parameters for the given pool operators.
    public func queryStakePoolParams(for pools: [PoolOperator]) async throws -> StakePoolParams {
        try await stateQuery.queryStakePoolParams(for: pools)
    }

    /// Query per-pool state for the given pools, or all pools if `nil`.
    public func queryPoolState(_ pools: [PoolOperator]? = nil) async throws -> PoolState {
        try await stateQuery.queryPoolState(pools)
    }

    /// Query stake snapshots (mark/set/go) for a specific pool, or all pools if `nil`.
    public func queryStakeSnapshots(for pool: PoolOperator? = nil) async throws -> StakeSnapshots {
        try await stateQuery.queryStakeSnapshots(for: pool)
    }

    /// Query the SPO stake distribution for the given pools, or all pools if `nil`.
    public func querySPOStakeDistr(_ pools: [PoolOperator]? = nil) async throws -> SPOStakeDistribution {
        try await stateQuery.querySPOStakeDistr(pools)
    }

    // MARK: - Rewards

    /// Query projected non-myopic member rewards for the given stake inputs.
    public func queryNonMyopicMemberRewards(
        _ inputs: [NonMyopicMemberRewardsInput]
    ) async throws -> NonMyopicMemberRewards {
        try await stateQuery.queryNonMyopicMemberRewards(inputs)
    }

    /// Query per-pool reward information for the current epoch.
    public func queryRewardInfoPools() async throws -> RewardInfoPools {
        try await stateQuery.queryRewardInfoPools()
    }

    /// Query detailed reward provenance data for the current epoch.
    public func queryRewardProvenance() async throws -> RewardProvenance {
        try await stateQuery.queryRewardProvenance()
    }

    // MARK: - Delegations and deposits

    /// Query filtered delegations and reward account summaries for the given stake credentials.
    public func queryFilteredDelegationsAndRewardAccounts(
        _ credentials: [any Credential]
    ) async throws -> FilteredDelegationsAndRewards {
        try await stateQuery.queryFilteredDelegationsAndRewardAccounts(credentials)
    }

    /// Query stake delegation deposit amounts for the given stake credentials.
    public func queryStakeDelegDeposits(
        _ credentials: [any Credential]
    ) async throws -> StakeDelegDeposits {
        try await stateQuery.queryStakeDelegDeposits(credentials)
    }

    // MARK: - Governance (Conway)

    /// Query the current Conway governance state.
    public func queryGovernanceState() async throws -> GovernanceState {
        try await stateQuery.queryGovernanceState()
    }

    /// Query the current constitution.
    public func queryConstitution() async throws -> LedgerConstitution {
        try await stateQuery.queryConstitution()
    }

    /// Query the current ratification state.
    public func queryRatifyState() async throws -> RatifyState {
        try await stateQuery.queryRatifyState()
    }

    /// Query the current account state (treasury and reserves).
    public func queryAccountState() async throws -> AccountState {
        try await stateQuery.queryAccountState()
    }

    /// Query on-chain state for the given DReps.
    public func queryDRepState(_ dreps: [DRep]) async throws -> DRepState {
        try await stateQuery.queryDRepState(dreps)
    }

    /// Query total delegated stake for the given DReps.
    public func queryDRepStakeDistr(_ dreps: [DRep]) async throws -> DRepStakeDistribution {
        try await stateQuery.queryDRepStakeDistr(dreps)
    }

    /// Query constitutional committee member states with optional cold/hot credential filters.
    public func queryCommitteeMembersState(
        _ filter: CommitteeMembersFilter = .all
    ) async throws -> CommitteeMembersState {
        try await stateQuery.queryCommitteeMembersState(filter)
    }

    /// Query the DRep each stake credential has delegated their vote to.
    public func queryFilteredVoteDelegatees(
        _ credentials: [any Credential]
    ) async throws -> VoteDelegatees {
        try await stateQuery.queryFilteredVoteDelegatees(credentials)
    }

    /// Query active governance proposals matching the given governance action IDs.
    public func queryProposals(_ govActionIDs: [GovActionID]) async throws -> ActiveProposals {
        try await stateQuery.queryProposals(govActionIDs)
    }

    // MARK: - Chain info

    /// Query the genesis configuration for the current era.
    public func queryGenesisConfig() async throws -> GenesisConfig {
        try await stateQuery.queryGenesisConfig()
    }

    /// Query the big ledger peer snapshot for peer bootstrapping.
    public func queryBigLedgerPeerSnapshot() async throws -> BigLedgerPeerSnapshot {
        try await stateQuery.queryBigLedgerPeerSnapshot()
    }

    // MARK: - Debug / serialised-blob queries (GetCBOR — tags 8, 12, 13)

    /// Query the full current epoch state (treasury, reserves, and opaque sub-structures).
    ///
    /// - Warning: This returns a very large response on mainnet.
    public func queryCurrentEpochState() async throws -> CurrentEpochState {
        try await stateQuery.queryCurrentEpochState()
    }

    /// Query the full new-epoch state (epoch number, block counts, pool distribution).
    ///
    /// - Warning: This returns a superset of `queryCurrentEpochState` and is even larger.
    public func queryDebugLedgerState() async throws -> DebugLedgerState {
        try await stateQuery.queryDebugLedgerState()
    }

    /// Query the consensus protocol state, including per-pool operational certificate counters.
    public func queryProtocolState() async throws -> ChainDepState {
        try await stateQuery.queryProtocolState()
    }

    // MARK: - Transaction submission

    /// Serialise and submit a fully-typed Conway `Transaction`.
    ///
    /// - Throws: `LocalTxSubmissionError.rejected(_:)` on node rejection.
    public func submit(_ tx: Transaction) async throws {
        try await txSubmission.submit(tx)
    }

    /// Submit a transaction and return its `TransactionId` on success.
    @discardableResult
    public func submitChecked(_ tx: Transaction) async throws -> TransactionId {
        try await txSubmission.submitChecked(tx)
    }

    // MARK: - Typed chain sync

    /// Stream full, decoded blocks via ChainSync.
    ///
    /// Equivalent to `chainSync.followTyped(from:)` but callable directly on
    /// the connection for convenience.
    public func follow(
        from points: [Point] = []
    ) -> AsyncThrowingStream<EraBlockEvent, Error> {
        chainSync.follow(from: points)
    }

    // MARK: - Typed mempool snapshot

    /// Snapshot the local mempool and return decoded `Transaction` values.
    public func snapshotMempool() async throws -> MempoolSnapshot {
        try await txMonitor.snapshotTyped()
    }

    // MARK: - Mempool extras

    /// Check whether a specific transaction is in the current mempool snapshot.
    ///
    /// Equivalent to `txMonitor.hasTx(_:)` but callable directly on the connection.
    public func hasTx(_ txId: TransactionId) async throws -> Bool {
        try await txMonitor.hasTx(txId.payload.byteArray)
    }

    /// Read mempool size metrics (capacity, current usage, transaction count).
    ///
    /// Equivalent to `txMonitor.sizes()` but callable directly on the connection.
    public func mempoolSizes() async throws -> MempoolCapacity {
        try await txMonitor.sizes()
    }

    /// Read extended mempool measures (totals plus named capacity/current pairs).
    ///
    /// Equivalent to `txMonitor.measuresTyped()` but callable directly on the connection.
    public func mempoolMeasures() async throws -> MempoolMeasures {
        try await txMonitor.measuresTyped()
    }
}
