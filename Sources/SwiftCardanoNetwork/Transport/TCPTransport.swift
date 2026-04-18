import NIOCore
import NIOPosix
import NIOExtras
import Logging
import Metrics

/// Establishes a Node-to-Node (NtN) TCP connection and builds the mux pipeline.
///
/// Returns a `(Channel, DemuxHandler)` pair. The caller registers mini-protocol
/// listeners on the `DemuxHandler` *before* calling this function (or directly
/// after obtaining the pair before any data arrives).
public struct TCPTransport: Sendable {
    private let config: ConnectionConfig
    private let protocolConfig: ProtocolConfig
    private let group: EventLoopGroup
    private let logger: Logger

    public init(
        config: ConnectionConfig,
        protocolConfig: ProtocolConfig,
        group: EventLoopGroup,
        logger: Logger = LoggerFactory.logger(subsystem: "transport")
    ) {
        self.config = config
        self.protocolConfig = protocolConfig
        self.group = group
        self.logger = logger
    }

    /// Connect to `config.host:config.port` and return the live channel + demux handler.
    public func connect() async throws -> (Channel, DemuxHandler) {
        let demux = DemuxHandler(
            logger: LoggerFactory.logger(subsystem: "mux")
        )
        let maxSDU = protocolConfig.ntnMaxSDUSize

        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { ch in
                do {
                    try ch.pipeline.syncOperations.addHandlers([
                        MessageToByteHandler(MuxFrameEncoder()),
                        ByteToMessageHandler(
                            MuxFrameDecoder(
                                maxPayloadSize: maxSDU,
                                logger: LoggerFactory.logger(subsystem: "mux"))
                        ),
                        demux,
                    ])
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: config.host, port: config.port)
            .get()

        logger.info("TCP connection opened", metadata: [
            "host": "\(config.host)",
            "port": "\(config.port)"
        ])

        CardanoMetrics
            .counter(
                CardanoMetrics.connectionsTotal,
                dimensions: [("network", "ntn"), ("result", "ok")]
            )
            .increment()
        CardanoMetrics
            .gauge(
                CardanoMetrics.connectionsActive,
                dimensions: [("network", "ntn")]
            )
            .record(1)

        return (channel, demux)
    }
}
