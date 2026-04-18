import NIOCore
import Logging
import Metrics

/// Performs the Handshake mini-protocol exchange and returns the negotiated version.
///
/// Usage:
/// ```swift
/// let client = HandshakeClient(channel: channel, demux: demux, config: config, mode: .nodeToClient)
/// let version = try await client.negotiate()
/// ```
public struct HandshakeClient: Sendable {
    private let channel: Channel
    private let demux: DemuxHandler
    private let config: ProtocolConfig
    private let mode: HandshakeCodec.Mode
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        config: ProtocolConfig,
        mode: HandshakeCodec.Mode,
        logger: Logger = LoggerFactory.logger(subsystem: "handshake")
    ) {
        self.channel = channel
        self.demux = demux
        self.config = config
        self.mode = mode
        self.logger = logger
    }

    /// Propose all configured versions; return the negotiated result or throw.
    public func negotiate(networkMagic: UInt32) async throws -> NegotiatedVersion {
        let startNanos = DispatchTime.now().uptimeNanoseconds

        let codec = HandshakeCodec(mode: mode)
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.handshake)

        let driver = ProtocolDriver(
            channel: channel,
            codec: codec,
            protocolID: MuxSDU.ProtocolID.handshake,
            initialState: HandshakeState.start,
            inboundStream: stream,
            protocolName: "handshake",
            logger: logger
        )

        let versions = buildVersionMap(networkMagic: networkMagic)

        logger.debug("Proposing handshake versions", metadata: [
            "versions": "\(Array(versions.keys).sorted(by: >))"
        ])

        try await driver.send(.proposeVersions(versions)) { state in
            guard let s = state as? HandshakeState else { return state }
            return try s.afterSend(.proposeVersions(versions))
        }

        let response = try await driver.receive { message, state in
            guard let s = state as? HandshakeState else { return state }
            return try s.afterReceive(message)
        }

        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startNanos
        CardanoMetrics
            .timer(CardanoMetrics.handshakeDurationSeconds, dimensions: [("network", networkLabel)])
            .recordNanoseconds(Int64(elapsedNanos))

        switch response {
        case .acceptVersion(let version, let vd):
            logger.info("Handshake accepted", metadata: [
                "version": "\(version)",
                "networkMagic": "\(networkMagic)"
            ])
            CardanoMetrics
                .counter(CardanoMetrics.handshakeTotal, dimensions: [("network", networkLabel), ("result", "accepted")])
                .increment()
            return NegotiatedVersion(version: version, versionData: vd)

        case .refuse(let reason):
            logger.error("Handshake refused", metadata: [
                "reason": "\(reason)",
                "versions": "\(Array(versions.keys).sorted(by: >))"
            ])
            CardanoMetrics
                .counter(CardanoMetrics.handshakeTotal, dimensions: [("network", networkLabel), ("result", "refused")])
                .increment()
            throw HandshakeError.refused(reason)

        case .proposeVersions:
            throw ProtocolError.invalidTransition(
                protocol: "handshake",
                state: "proposed",
                message: "proposeVersions"
            )
        }
    }

    // MARK: - Helpers

    private var networkLabel: String { mode == .nodeToNode ? "ntn" : "ntc" }

    private func buildVersionMap(networkMagic: UInt32) -> [UInt16: HandshakeVersionData] {
        let versions = mode == .nodeToNode ? config.ntnVersions : config.ntcVersions
        return Dictionary(uniqueKeysWithValues: versions.map { v in
            switch mode {
            case .nodeToNode:
                let peerSharing: UInt8? = v >= NodeToNodeVersion.v11 ? 0 : nil
                let query: Bool? = v >= NodeToNodeVersion.v13 ? false : nil
                return (v, HandshakeVersionData.nodeToNode(networkMagic: networkMagic, initiatorOnly: false, peerSharing: peerSharing, query: query))
            case .nodeToClient:
                return (v, HandshakeVersionData.nodeToClient(networkMagic: networkMagic))
            }
        })
    }
}

import Dispatch
