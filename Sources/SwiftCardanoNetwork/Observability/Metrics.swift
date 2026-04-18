import Metrics

/// Centralised metric name constants and factory helpers.
/// All metric names follow the Prometheus convention: `<namespace>_<subsystem>_<unit>`.
public enum CardanoMetrics {

    // MARK: - Counters

    public static let bytesReceivedTotal       = "cardano_network_bytes_received_total"
    public static let bytesSentTotal           = "cardano_network_bytes_sent_total"
    public static let connectionsTotal         = "cardano_network_connections_total"
    public static let reconnectionsTotal       = "cardano_network_reconnections_total"
    public static let handshakeTotal           = "cardano_network_handshake_total"
    public static let blocksReceivedTotal      = "cardano_network_blocks_received_total"
    public static let rollbacksTotal           = "cardano_network_rollbacks_total"
    public static let txSubmissionsTotal       = "cardano_network_tx_submissions_total"
    public static let sduDecodeErrorsTotal     = "cardano_network_sdu_decode_errors_total"
    public static let agencyViolationsTotal    = "cardano_network_agency_violations_total"

    // MARK: - Gauges

    public static let connectionsActive        = "cardano_network_connections_active"
    public static let chainTipSlot             = "cardano_network_chain_tip_slot"
    public static let chainTipBlock            = "cardano_network_chain_tip_block"
    public static let mempoolTxCount           = "cardano_network_mempool_tx_count"
    public static let mempoolCapacityBytes     = "cardano_network_mempool_capacity_bytes"

    // MARK: - Timers

    public static let handshakeDurationSeconds      = "cardano_network_handshake_duration_seconds"
    public static let blockFetchDurationSeconds     = "cardano_network_block_fetch_duration_seconds"
    public static let queryDurationSeconds          = "cardano_network_query_duration_seconds"
    public static let keepAliveRTTSeconds           = "cardano_network_keepalive_rtt_seconds"
    public static let txSubmissionDurationSeconds   = "cardano_network_tx_submission_duration_seconds"

    // MARK: - Dimension keys

    public enum Dimension {
        public static let network  = "network"   // "ntn" or "ntc"
        public static let result   = "result"    // "ok", "error", "accepted", "rejected"
        public static let `protocol` = "protocol"  // mini-protocol name
        public static let query    = "query"     // LocalStateQuery query name
    }
}

// MARK: - Convenience factory

extension CardanoMetrics {
    public static func counter(_ name: String, dimensions: [(String, String)] = []) -> Counter {
        Counter(label: name, dimensions: dimensions)
    }

    public static func gauge(_ name: String, dimensions: [(String, String)] = []) -> Gauge {
        Gauge(label: name, dimensions: dimensions)
    }

    public static func timer(_ name: String, dimensions: [(String, String)] = []) -> Metrics.Timer {
        Metrics.Timer(label: name, dimensions: dimensions)
    }
}
