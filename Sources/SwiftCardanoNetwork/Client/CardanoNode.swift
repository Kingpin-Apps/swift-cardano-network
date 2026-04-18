import Logging
import NIOCore
import NIOPosix

/// Top-level factory for Cardano network connections.
///
/// Use `connectToClient` to talk to a local `cardano-node` process over a Unix
/// domain socket (NtC), or `connectToNode` to connect to a remote Cardano peer
/// over TCP (NtN).
///
/// ## Node-to-Client  (local node, Unix socket)
///
/// ```swift
/// var config = CardanoNetworkConfiguration.mainnet
/// config.connection.socketPath = "/ipc/node.socket"
///
/// let ntc = try await CardanoNode.connectToClient(config: config)
/// defer { await ntc.close() }
///
/// for try await event in ntc.chainSync.follow() { … }
/// ```
///
/// ## Node-to-Node  (remote peer, TCP)
///
/// ```swift
/// let ntn = try await CardanoNode.connectToNode(config: .mainnet)
/// defer { await ntn.close() }
///
/// for try await event in ntn.chainSync.follow() { … }
/// ```
public enum CardanoNode {

    // MARK: - NtC factory

    /// Connect to a local `cardano-node` using the Node-to-Client protocol
    /// (Unix domain socket).
    ///
    /// The returned `NodeToClientConnection` has already successfully completed
    /// the Handshake negotiation and is ready for use.
    ///
    /// - Parameters:
    ///   - config: Full connection/protocol configuration.
    ///     `config.connection.socketPath` must be set to the path of the
    ///     running node's socket (e.g. `"/ipc/node.socket"`).
    ///   - group: The NIO event-loop group to use.  Defaults to the process-wide
    ///     `MultiThreadedEventLoopGroup.singleton`.
    /// - Returns: A ready-to-use `NodeToClientConnection`.
    /// - Throws: `TransportError.missingSocketPath` if no socket path is
    ///   configured, or a `HandshakeError` if version negotiation fails.
    public static func connectToClient(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> NodeToClientConnection {
        let conn = config.connection
        let proto = config.`protocol`

        let (channel, demux) = try await UnixSocketTransport(
            config: conn,
            protocolConfig: proto,
            group: group
        ).connect()

        _ = try await HandshakeClient(
            channel: channel,
            demux: demux,
            config: proto,
            mode: .nodeToClient
        ).negotiate(networkMagic: conn.networkMagic)

        return NodeToClientConnection(channel: channel, demux: demux)
    }

    // MARK: - NtN factory

    /// Connect to a remote Cardano node using the Node-to-Node protocol (TCP).
    ///
    /// The returned `NodeToNodeConnection` has already successfully completed
    /// the Handshake negotiation and automatically runs a KeepAlive probe loop
    /// in the background until `close()` is called.
    ///
    /// - Parameters:
    ///   - config: Full connection/protocol configuration.
    ///     `config.connection.host` and `.port` must identify a reachable
    ///     Cardano node.  Use the `.mainnet`, `.preview`, or `.preprod` presets
    ///     or build a custom `CardanoNetworkConfiguration`.
    ///   - group: The NIO event-loop group to use.  Defaults to the process-wide
    ///     `MultiThreadedEventLoopGroup.singleton`.
    /// - Returns: A ready-to-use `NodeToNodeConnection`.
    /// - Throws: An NIO connection error if the host is unreachable, or a
    ///   `HandshakeError` if version negotiation fails.
    public static func connectToNode(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> NodeToNodeConnection {
        let conn = config.connection
        let proto = config.`protocol`

        let (channel, demux) = try await TCPTransport(
            config: conn,
            protocolConfig: proto,
            group: group
        ).connect()

        _ = try await HandshakeClient(
            channel: channel,
            demux: demux,
            config: proto,
            mode: .nodeToNode
        ).negotiate(networkMagic: conn.networkMagic)

        return NodeToNodeConnection(channel: channel, demux: demux, protocolConfig: proto)
    }
}
