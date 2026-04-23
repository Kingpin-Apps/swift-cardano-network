import NIOCore
import SwiftCardanoCore

// MARK: - NodeToNodeConnection typed convenience API
//
// Thin shorthands that delegate to the typed extensions on the individual
// mini-protocol clients.  Nothing in NodeToNodeConnection is modified; callers
// that do not need decoded types are completely unaffected.

extension NodeToNodeConnection {

    // MARK: - Typed chain sync (headers)

    /// Stream decoded block headers via NtN ChainSync.
    ///
    /// NtN ChainSync delivers **block headers only** — not full blocks.  Use
    /// `blockFetch.fetch(from:to:)` to download block bodies for any header
    /// you want to inspect further.
    ///
    /// Handles Shelley through Conway automatically:
    /// - **Shelley / Allegra / Mary** — 15-field inline header body.
    /// - **Alonzo / Babbage / Conway** — 14-field inline header body.
    ///
    /// Byron headers (era 0) will cause the stream to throw. If you need to
    /// handle Byron, use the raw `chainSync.follow(from:)` and check `rawBlock.era`.
    ///
    /// ```swift
    /// let connection = try await CardanoNode.connectToNode(config: .preprod)
    /// defer { await connection.close() }
    ///
    /// for try await event in connection.follow() {
    ///     if case .rollForward(let header, let tip) = event {
    ///         print("Slot \(header.headerBody.slot), blockNo \(header.headerBody.blockNumber), tip \(tip.blockNo)")
    ///     }
    /// }
    /// ```
    ///
    /// Equivalent to `chainSync.follow(from:)` but callable directly
    /// on the connection.
    public func follow(
        from points: [Point] = []
    ) -> AsyncThrowingStream<EraHeaderEvent, Error> {
        chainSync.follow(from: points)
    }

    // MARK: - BlockFetch

    /// Download and decode all block bodies in the chain range `[from, to]`.
    ///
    /// Equivalent to `blockFetch.fetch(from:to:)` but callable directly on
    /// the connection.  Each raw block body is decoded into a typed
    /// SwiftCardanoCore `EraBlock`.
    ///
    /// Throws `BlockFetchError.emptyBatch` if the peer has no blocks in range,
    /// `BlockFetchDecodeError` if the era wrapper is malformed, or a
    /// `CardanoCoreError` if block CBOR cannot be parsed.
    public func fetch(
        from startPoint: Point,
        to endPoint: Point
    ) async throws -> [EraBlock] {
        try await blockFetch.fetch(from: startPoint, to: endPoint)
    }

    // MARK: - TxSubmission2

    /// Start the TxSubmission2 serve loop, delegating mempool access to `provider`.
    ///
    /// Equivalent to `txSubmission2.run(provider:)` but callable directly on
    /// the connection.  Suspends until the remote sends `MsgDone` or the
    /// enclosing `Task` is cancelled.
    public func serveTransactions(provider: some TxSubmissionProvider) async throws {
        try await txSubmission2.run(provider: provider)
    }
}
