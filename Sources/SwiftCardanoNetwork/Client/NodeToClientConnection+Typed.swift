import NIOCore
import SwiftCardanoCore

// MARK: - NodeToClientConnection typed convenience API
//
// These methods are thin shorthands that delegate to the typed extensions on
// the individual mini-protocol clients.  Nothing in the existing
// NodeToClientConnection struct is modified; callers who do not import
// SwiftCardanoCore are completely unaffected.

extension NodeToClientConnection {

    // MARK: - Ledger state queries

    /// Query the UTxO set filtered to the given addresses.
    public func queryUTxO(for addresses: [Address]) async throws -> [UTxO] {
        try await stateQuery.queryUTxO(for: addresses)
    }

    /// Query the UTxO set filtered to the given transaction inputs.
    public func queryUTxO(for inputs: [TransactionInput]) async throws -> [UTxO] {
        try await stateQuery.queryUTxO(for: inputs)
    }

    /// Query the current protocol parameters (returned as raw CBOR).
    ///
    /// See `LocalStateQueryClient.queryProtocolParameters()` for details.
    public func queryProtocolParameters() async throws -> ProtocolParameters {
        try await stateQuery.queryProtocolParameters()
    }

    /// Query the current ledger tip as a `Point`.
    public func queryLedgerTip() async throws -> Point {
        try await stateQuery.queryLedgerTip()
    }

    /// Query the current epoch number.
    public func queryEpochNo() async throws -> UInt64 {
        try await stateQuery.queryEpochNo()
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
    public func snapshotMempool() async throws -> (slotNo: UInt64, txs: [Transaction]) {
        try await txMonitor.snapshotTyped()
    }

    // MARK: - Mempool extras

    /// Check whether a specific transaction is in the current mempool snapshot.
    ///
    /// Equivalent to `txMonitor.hasTx(_:)` but callable directly on the connection.
    public func hasTx(_ txId: TxId) async throws -> Bool {
        try await txMonitor.hasTx(txId)
    }

    /// Read mempool size metrics (capacity, current usage, transaction count).
    ///
    /// Equivalent to `txMonitor.sizes()` but callable directly on the connection.
    public func mempoolSizes() async throws -> MempoolCapacity {
        try await txMonitor.sizes()
    }

    /// Read extended mempool measures (totals plus named capacity/current pairs).
    ///
    /// Equivalent to `txMonitor.measures()` but callable directly on the connection.
    public func mempoolMeasures() async throws
        -> (totalTxs: UInt32, measures: [(key: String, current: Int64, capacity: Int64)])
    {
        try await txMonitor.measures()
    }
}
