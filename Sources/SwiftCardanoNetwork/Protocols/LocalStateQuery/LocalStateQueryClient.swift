import NIOCore
import Logging
import Metrics
import Dispatch

/// Runs the LocalStateQuery mini-protocol (NtC, protocol ID 7) and exposes
/// a single `query(_:at:)` call.
///
/// ## Usage
///
/// ```swift
/// let client = LocalStateQueryClient(channel: channel, demux: demux)
///
/// // Query at the node's current volatile tip (most common)
/// var qBuf = allocator.buffer(capacity: rawCBOR.count)
/// qBuf.writeBytes(rawCBOR)
/// let result = try await client.query(.raw(RawQuery(era: 6, rawCBOR: qBuf)))
///
/// // Query at a specific immutable chain point
/// let result = try await client.query(
///     .raw(RawQuery(era: 6, rawCBOR: qBuf)),
///     at: .specific(.blockPoint(slot: 1_000_000, hash: hash))
/// )
/// ```
///
/// Each call acquires a snapshot → runs the query → releases the snapshot in a
/// single round-trip session. The ProtocolDriver is created fresh per call,
/// which is safe because the protocol returns to `Idle` after release.
///
/// Query duration is recorded as `cardano_network_query_duration_seconds`.
public struct LocalStateQueryClient: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger

    /// The negotiated NtC wire version this client is operating against.
    ///
    /// Set by `NodeToClientConnection` after Handshake completes.  Query
    /// factories in `LedgerQuery+Typed.swift` consult this (via `NtcQueryGate`)
    /// to choose the correct CBOR tag for queries whose wire encoding changed
    /// across NtC versions and to refuse early when a caller asks for a query
    /// the negotiated version cannot service.  Defaults to `0` for direct
    /// callers and tests that don't go through `NodeToClientConnection`.
    public let negotiatedVersion: UInt16

    public init(
        channel: Channel,
        demux: DemuxHandler,
        negotiatedVersion: UInt16 = 0,
        logger: Logger = LoggerFactory.logger(subsystem: "localstatequery")
    ) {
        self.channel = channel
        self.demux = demux
        self.negotiatedVersion = negotiatedVersion
        self.logger = logger
    }

    // MARK: - Public API

    /// Query the ledger at the node's current volatile tip.
    ///
    /// - Parameter query: The pre-encoded era-tagged ledger query.
    /// - Returns: The era-tagged result from the node.
    /// - Throws: `LocalStateQueryError.acquireFailed` if the node cannot serve
    ///   the volatile tip, or a `ProtocolError` on protocol violations.
    public func query(_ query: LedgerQuery) async throws -> RawResult {
        try await self.query(query, at: .volatileTip)
    }

    /// Query the ledger at a specific chain point.
    ///
    /// Internally: acquires a snapshot at `point` → runs the query → releases.
    ///
    /// - Parameters:
    ///   - query: The pre-encoded era-tagged ledger query.
    ///   - point: The chain snapshot to acquire.
    /// - Returns: The era-tagged result from the node.
    /// - Throws: `LocalStateQueryError.acquireFailed` if the node cannot serve
    ///   the requested point, or a `ProtocolError` on protocol violations.
    public func query(_ query: LedgerQuery, at point: AcquirePoint) async throws -> RawResult {
        let driver   = makeDriver()
        let rawQuery = query.rawQuery
        let start    = DispatchTime.now()

        // ── Step 1: Acquire ──────────────────────────────────────────────────
        let acquireMsg: LocalStateQueryMessage
        switch point {
        case .volatileTip:      acquireMsg = .acquireVolatileTip
        case .specific(let p): acquireMsg = .acquire(p)
        }

        logger.debug("LocalStateQuery: acquiring", metadata: ["point": "\(point)"])

        try await driver.send(acquireMsg) { state in
            guard let s = state as? LocalStateQueryState else { return state }
            return try s.afterSend(acquireMsg)
        }

        let acquireResponse = try await driver.receive { msg, state in
            guard let s = state as? LocalStateQueryState else { return state }
            return try s.afterReceive(msg)
        }

        switch acquireResponse {
        case .acquired:
            logger.debug("LocalStateQuery: acquired")

        case .failure(let f):
            logger.warning("LocalStateQuery: acquire failed", metadata: ["reason": "\(f)"])
            throw LocalStateQueryError.acquireFailed(f)

        default:
            throw ProtocolError.invalidTransition(
                protocol: "localStateQuery",
                state: "acquiring",
                message: String(describing: acquireResponse)
            )
        }

        // ── Step 2: Query ────────────────────────────────────────────────────
        logger.debug("LocalStateQuery: sending query", metadata: [
            "era":   "\(rawQuery.era)",
            "bytes": "\(rawQuery.rawCBOR.readableBytes)"
        ])

        try await driver.send(.query(rawQuery)) { state in
            guard let s = state as? LocalStateQueryState else { return state }
            return try s.afterSend(.query(rawQuery))
        }

        let queryResponse = try await driver.receive { msg, state in
            guard let s = state as? LocalStateQueryState else { return state }
            return try s.afterReceive(msg)
        }

        guard case .result(let rawResult) = queryResponse else {
            throw ProtocolError.invalidTransition(
                protocol: "localStateQuery",
                state: "querying",
                message: String(describing: queryResponse)
            )
        }

        logger.debug("LocalStateQuery: received result", metadata: [
            "era":   "\(rawResult.era)",
            "bytes": "\(rawResult.rawCBOR.readableBytes)"
        ])

        // ── Step 3: Release ──────────────────────────────────────────────────
        try await driver.send(.release) { state in
            guard let s = state as? LocalStateQueryState else { return state }
            return try s.afterSend(.release)
        }

        let elapsed = start.distance(to: .now())
        CardanoMetrics
            .timer(CardanoMetrics.queryDurationSeconds, dimensions: [("query", "raw")])
            .recordNanoseconds(elapsed.nanoseconds)

        return rawResult
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<LocalStateQueryCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.localStateQuery)
        return ProtocolDriver(
            channel: channel,
            codec: LocalStateQueryCodec(),
            protocolID: MuxSDU.ProtocolID.localStateQuery,
            initialState: LocalStateQueryState.idle,
            inboundStream: stream,
            protocolName: "localStateQuery",
            logger: logger
        )
    }
}

// MARK: - DispatchTimeInterval helpers

private extension DispatchTimeInterval {
    var nanoseconds: Int64 {
        switch self {
        case .nanoseconds(let n):  return Int64(n)
        case .microseconds(let n): return Int64(n) * 1_000
        case .milliseconds(let n): return Int64(n) * 1_000_000
        case .seconds(let n):      return Int64(n) * 1_000_000_000
        case .never:               return 0
        @unknown default:          return 0
        }
    }
}
