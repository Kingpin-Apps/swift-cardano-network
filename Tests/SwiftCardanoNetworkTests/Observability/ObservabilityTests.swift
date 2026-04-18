import Testing
import Logging
import Metrics
@testable import SwiftCardanoNetwork

// MARK: - LoggerFactory

@Suite("LoggerFactory", .serialized) struct LoggerFactoryTests {
    @Test func defaultLabelPrefix() {
        // Default prefix is "cardano-network".
        let log = LoggerFactory.logger(subsystem: "test")
        #expect(log.label == "cardano-network.test")
    }

    @Test func configureChangesPrefix() {
        var cfg = LoggingConfig()
        cfg.labelPrefix = "my-app"
        LoggerFactory.configure(cfg)
        let log = LoggerFactory.logger(subsystem: "mux")
        #expect(log.label == "my-app.mux")

        // Restore default so other tests are unaffected.
        LoggerFactory.configure(LoggingConfig())
    }

    @Test func configureChangesLogLevel() {
        var cfg = LoggingConfig()
        cfg.level = .trace
        LoggerFactory.configure(cfg)
        let log = LoggerFactory.logger(subsystem: "handshake")
        #expect(log.logLevel == .trace)

        LoggerFactory.configure(LoggingConfig())
    }

    @Test func subsystemAppearsInLabel() {
        let subsystems = ["transport", "mux", "handshake", "chainsync", "driver"]
        for subsystem in subsystems {
            let log = LoggerFactory.logger(subsystem: subsystem)
            #expect(log.label.hasSuffix(".\(subsystem)"))
        }
    }
}

// MARK: - CardanoMetrics — name constants

@Suite("CardanoMetrics") struct CardanoMetricsTests {
    // Counters
    @Test func counterNameConstants() {
        #expect(CardanoMetrics.bytesReceivedTotal    == "cardano_network_bytes_received_total")
        #expect(CardanoMetrics.bytesSentTotal        == "cardano_network_bytes_sent_total")
        #expect(CardanoMetrics.connectionsTotal      == "cardano_network_connections_total")
        #expect(CardanoMetrics.reconnectionsTotal    == "cardano_network_reconnections_total")
        #expect(CardanoMetrics.handshakeTotal        == "cardano_network_handshake_total")
        #expect(CardanoMetrics.blocksReceivedTotal   == "cardano_network_blocks_received_total")
        #expect(CardanoMetrics.rollbacksTotal        == "cardano_network_rollbacks_total")
        #expect(CardanoMetrics.txSubmissionsTotal    == "cardano_network_tx_submissions_total")
        #expect(CardanoMetrics.sduDecodeErrorsTotal  == "cardano_network_sdu_decode_errors_total")
        #expect(CardanoMetrics.agencyViolationsTotal == "cardano_network_agency_violations_total")
    }

    // Gauges
    @Test func gaugeNameConstants() {
        #expect(CardanoMetrics.connectionsActive   == "cardano_network_connections_active")
        #expect(CardanoMetrics.chainTipSlot        == "cardano_network_chain_tip_slot")
        #expect(CardanoMetrics.chainTipBlock       == "cardano_network_chain_tip_block")
        #expect(CardanoMetrics.mempoolTxCount      == "cardano_network_mempool_tx_count")
        #expect(CardanoMetrics.mempoolCapacityBytes == "cardano_network_mempool_capacity_bytes")
    }

    // Timers
    @Test func timerNameConstants() {
        #expect(CardanoMetrics.handshakeDurationSeconds     == "cardano_network_handshake_duration_seconds")
        #expect(CardanoMetrics.blockFetchDurationSeconds    == "cardano_network_block_fetch_duration_seconds")
        #expect(CardanoMetrics.queryDurationSeconds         == "cardano_network_query_duration_seconds")
        #expect(CardanoMetrics.keepAliveRTTSeconds          == "cardano_network_keepalive_rtt_seconds")
        #expect(CardanoMetrics.txSubmissionDurationSeconds  == "cardano_network_tx_submission_duration_seconds")
    }

    // Dimension keys
    @Test func dimensionKeyConstants() {
        #expect(CardanoMetrics.Dimension.network  == "network")
        #expect(CardanoMetrics.Dimension.result   == "result")
        #expect(CardanoMetrics.Dimension.`protocol` == "protocol")
        #expect(CardanoMetrics.Dimension.query    == "query")
    }

    // All metric names follow the `cardano_network_` prefix convention.
    @Test func allNamesHaveCorrectPrefix() {
        let allNames: [String] = [
            CardanoMetrics.bytesReceivedTotal, CardanoMetrics.bytesSentTotal,
            CardanoMetrics.connectionsTotal, CardanoMetrics.reconnectionsTotal,
            CardanoMetrics.handshakeTotal, CardanoMetrics.blocksReceivedTotal,
            CardanoMetrics.rollbacksTotal, CardanoMetrics.txSubmissionsTotal,
            CardanoMetrics.sduDecodeErrorsTotal, CardanoMetrics.agencyViolationsTotal,
            CardanoMetrics.connectionsActive, CardanoMetrics.chainTipSlot,
            CardanoMetrics.chainTipBlock, CardanoMetrics.mempoolTxCount,
            CardanoMetrics.mempoolCapacityBytes, CardanoMetrics.handshakeDurationSeconds,
            CardanoMetrics.blockFetchDurationSeconds, CardanoMetrics.queryDurationSeconds,
            CardanoMetrics.keepAliveRTTSeconds, CardanoMetrics.txSubmissionDurationSeconds,
        ]
        for name in allNames {
            #expect(name.hasPrefix("cardano_network_"), "Name '\(name)' lacks prefix")
        }
    }

    // Factory helpers return usable metric objects (smoke test — no backend registered).
    @Test func factoryHelpersDoNotCrash() {
        _ = CardanoMetrics.counter(CardanoMetrics.connectionsTotal, dimensions: [("network", "ntc")])
        _ = CardanoMetrics.gauge(CardanoMetrics.connectionsActive, dimensions: [("network", "ntn")])
        _ = CardanoMetrics.timer(CardanoMetrics.handshakeDurationSeconds, dimensions: [("network", "ntc")])
    }
}
