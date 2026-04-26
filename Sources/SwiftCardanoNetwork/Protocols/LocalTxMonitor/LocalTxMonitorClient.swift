import NIOCore
import Logging
import Metrics

/// Runs the LocalTxMonitor mini-protocol (NtC, protocol ID 9) to inspect the
/// node's mempool.
///
/// ## Usage
///
/// ```swift
/// let client = LocalTxMonitorClient(channel: channel, demux: demux)
///
/// // Collect all pending transactions in the current mempool snapshot
/// let (slotNo, txs) = try await client.snapshot()
/// print("Mempool at slot \(slotNo): \(txs.count) transaction(s)")
///
/// // Check if a specific transaction is in the mempool
/// let present = try await client.hasTx(myTxId)
///
/// // Get mempool capacity metrics
/// let cap = try await client.capacity()
/// ```
///
/// Each call acquires a snapshot → performs the query → releases the snapshot.
/// Snapshot metrics are emitted as `cardano_network_mempool_tx_count` and
/// `cardano_network_mempool_capacity_bytes`.
public struct LocalTxMonitorClient: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let logger: Logger
    /// Raw NtC handshake version (e.g. `32787` for v19).  `0` means unknown,
    /// in which case version-gated calls don't pre-flight check.  See
    /// `LocalTxMonitorError.measuresNotSupported` for the gating logic.
    private let negotiatedVersion: UInt16

    public init(
        channel: Channel,
        demux: DemuxHandler,
        negotiatedVersion: UInt16 = 0,
        logger: Logger = LoggerFactory.logger(subsystem: "localtxmonitor")
    ) {
        self.channel = channel
        self.demux = demux
        self.negotiatedVersion = negotiatedVersion
        self.logger = logger
    }

    // MARK: - Public API

    /// Acquire a mempool snapshot and return all transactions it contains.
    ///
    /// - Returns: The slot number of the snapshot and an array of raw transactions.
    /// - Throws: A `ProtocolError` on agency or state-machine violations.
    public func snapshot() async throws -> (slotNo: UInt64, txs: [MempoolTx]) {
        let driver = makeDriver()

        // ── Acquire ──────────────────────────────────────────────────────────
        let slotNo = try await acquire(driver: driver)

        // ── Enumerate transactions ────────────────────────────────────────────
        var txs: [MempoolTx] = []
        while true {
            try await driver.send(.nextTx) { state in
                guard let s = state as? LocalTxMonitorState else { return state }
                return try s.afterSend(.nextTx)
            }

            let reply = try await driver.receive { msg, state in
                guard let s = state as? LocalTxMonitorState else { return state }
                return try s.afterReceive(msg)
            }

            guard case .replyNextTx(let tx) = reply else {
                throw ProtocolError.invalidTransition(
                    protocol: "localTxMonitor",
                    state: "busy",
                    message: String(describing: reply)
                )
            }

            guard let tx else { break }
            txs.append(tx)
        }

        logger.debug("LocalTxMonitor: snapshot enumerated", metadata: [
            "slotNo": "\(slotNo)",
            "txCount": "\(txs.count)"
        ])

        CardanoMetrics
            .gauge(CardanoMetrics.mempoolTxCount)
            .record(Double(txs.count))

        // ── Release ───────────────────────────────────────────────────────────
        try await release(driver: driver)

        return (slotNo: slotNo, txs: txs)
    }

    /// Acquire a mempool snapshot and check whether `txId` is present.
    ///
    /// The cardano-node mempool stores transactions under era-wrapped IDs
    /// (`OneEraGenTxId`) and does not normalise lookups across eras, so a query
    /// for a Conway hash will return `false` if the tx is currently sitting in
    /// the Babbage codec path.  This method probes each post-Byron era
    /// (newest-first) within a single snapshot until the node confirms the tx
    /// is present, mirroring the workaround documented in Ogmios 6.2.0 release
    /// notes and IntersectMBO/ouroboros-consensus#1009.
    ///
    /// - Parameter txId: The 32-byte transaction identifier to look up.
    /// - Returns: `true` if any era reports the transaction in the current
    ///   mempool snapshot.
    /// - Throws: A `ProtocolError` on agency or state-machine violations.
    public func hasTx(_ txId: TxId) async throws -> Bool {
        let driver = makeDriver()

        _ = try await acquire(driver: driver)

        for eraIndex in CardanoEraIndex.hasTxRetryOrder {
            let msg: LocalTxMonitorMessage = .hasTx(eraIndex: eraIndex, txId: txId)

            try await driver.send(msg) { state in
                guard let s = state as? LocalTxMonitorState else { return state }
                return try s.afterSend(msg)
            }

            let reply = try await driver.receive { m, state in
                guard let s = state as? LocalTxMonitorState else { return state }
                return try s.afterReceive(m)
            }

            guard case .replyHasTx(let present) = reply else {
                throw ProtocolError.invalidTransition(
                    protocol: "localTxMonitor",
                    state: "busy",
                    message: String(describing: reply)
                )
            }

            if present {
                logger.debug("LocalTxMonitor: hasTx", metadata: [
                    "present": "true",
                    "eraIndex": "\(eraIndex)",
                ])
                try await release(driver: driver)
                return true
            }
        }

        logger.debug("LocalTxMonitor: hasTx", metadata: ["present": "false"])
        try await release(driver: driver)
        return false
    }

    /// Acquire a mempool snapshot and return the current size metrics.
    ///
    /// - Returns: The current `MempoolCapacity` (byte limits and transaction count).
    /// - Throws: A `ProtocolError` on agency or state-machine violations.
    public func sizes() async throws -> MempoolCapacity {
        let driver = makeDriver()

        _ = try await acquire(driver: driver)

        try await driver.send(.getSizes) { state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterSend(.getSizes)
        }

        let reply = try await driver.receive { msg, state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterReceive(msg)
        }

        guard case .replyGetSizes(let cap) = reply else {
            throw ProtocolError.invalidTransition(
                protocol: "localTxMonitor",
                state: "busy",
                message: String(describing: reply)
            )
        }

        logger.debug("LocalTxMonitor: sizes", metadata: [
            "capacityBytes": "\(cap.capacityInBytes)",
            "sizeBytes":     "\(cap.sizeInBytes)",
            "txCount":       "\(cap.numberOfTxs)"
        ])

        CardanoMetrics
            .gauge(CardanoMetrics.mempoolCapacityBytes)
            .record(Double(cap.capacityInBytes))
        CardanoMetrics
            .gauge(CardanoMetrics.mempoolTxCount)
            .record(Double(cap.numberOfTxs))

        try await release(driver: driver)

        return cap
    }

    /// Acquire a mempool snapshot and return extended measure data.
    ///
    /// `MsgGetMeasures` was added in NtC v19.  When the connection has
    /// negotiated a lower version (the library default tops out at v16) this
    /// call would otherwise be silently rejected by the node — so it instead
    /// throws `LocalTxMonitorError.measuresNotSupported` up-front.  Override
    /// `ProtocolConfig.ntcVersions` to include v19+ to enable the call.
    ///
    /// - Returns: Total transaction count and a map of named measure pairs (current, capacity).
    /// - Throws: `LocalTxMonitorError.measuresNotSupported` if NtC < v19;
    ///   `ProtocolError` on agency or state-machine violations.
    public func measures() async throws -> (totalTxs: UInt32, measures: [(key: String, current: Int64, capacity: Int64)]) {
        let required: UInt16 = 32787  // NtC v19
        if negotiatedVersion != 0 && negotiatedVersion < required {
            throw LocalTxMonitorError.measuresNotSupported(
                negotiatedVersion: negotiatedVersion, requiredVersion: required)
        }

        let driver = makeDriver()

        _ = try await acquire(driver: driver)

        try await driver.send(.getMeasures) { state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterSend(.getMeasures)
        }

        let reply = try await driver.receive { msg, state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterReceive(msg)
        }

        guard case .replyGetMeasures(let totalTxs, let ms) = reply else {
            throw ProtocolError.invalidTransition(
                protocol: "localTxMonitor",
                state: "busy",
                message: String(describing: reply)
            )
        }

        logger.debug("LocalTxMonitor: measures", metadata: ["totalTxs": "\(totalTxs)"])

        try await release(driver: driver)

        return (totalTxs: totalTxs, measures: ms)
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<LocalTxMonitorCodec> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.localTxMonitor)
        return ProtocolDriver(
            channel: channel,
            codec: LocalTxMonitorCodec(),
            protocolID: MuxSDU.ProtocolID.localTxMonitor,
            initialState: LocalTxMonitorState.idle,
            inboundStream: stream,
            protocolName: "localTxMonitor",
            logger: logger
        )
    }

    private func acquire(driver: ProtocolDriver<LocalTxMonitorCodec>) async throws -> UInt64 {
        logger.debug("LocalTxMonitor: acquiring snapshot")

        try await driver.send(.acquire) { state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterSend(.acquire)
        }

        let reply = try await driver.receive { msg, state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterReceive(msg)
        }

        guard case .acquired(let slotNo) = reply else {
            throw ProtocolError.invalidTransition(
                protocol: "localTxMonitor",
                state: "acquiring",
                message: String(describing: reply)
            )
        }

        logger.debug("LocalTxMonitor: acquired snapshot", metadata: ["slotNo": "\(slotNo)"])
        return slotNo
    }

    private func release(driver: ProtocolDriver<LocalTxMonitorCodec>) async throws {
        try await driver.send(.release) { state in
            guard let s = state as? LocalTxMonitorState else { return state }
            return try s.afterSend(.release)
        }
        logger.debug("LocalTxMonitor: released snapshot")
    }
}
