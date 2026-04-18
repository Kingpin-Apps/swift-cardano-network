import NIOCore
import NIOPosix
import NIOExtras
import Logging
import Metrics

/// Establishes a Node-to-Client (NtC) Unix domain socket connection and builds
/// the mux pipeline.
public struct UnixSocketTransport: Sendable {
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

    /// Connect to `config.socketPath` and return the live channel + demux handler.
    public func connect() async throws -> (Channel, DemuxHandler) {
        guard let socketPath = config.socketPath else {
            throw TransportError.missingSocketPath
        }

        let demux = DemuxHandler(logger: LoggerFactory.logger(subsystem: "mux"))
        let maxSDU = protocolConfig.ntcMaxSDUSize

        let channel = try await ClientBootstrap(group: group)
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
            .connect(unixDomainSocketPath: socketPath)
            .get()

        logger.info(
            "Unix socket connection opened",
            metadata: ["socketPath": "\(socketPath)"])

        CardanoMetrics
            .counter(
                CardanoMetrics.connectionsTotal,
                dimensions: [("network", "ntc"), ("result", "ok")])
            .increment()
        CardanoMetrics
            .gauge(
                CardanoMetrics.connectionsActive,
                dimensions: [("network", "ntc")]
            )
            .record(1)

        return (channel, demux)
    }
}

public enum TransportError: Error, Sendable {
    case missingSocketPath
}
