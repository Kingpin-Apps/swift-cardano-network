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
/// try await CardanoNode.withClient(config: config) { connection in
///     for try await event in connection.chainSync.follow() { … }
/// }
/// ```
///
/// ## Node-to-Node  (remote peer, TCP)
///
/// ```swift
/// try await CardanoNode.withNode(config: .mainnet) { connection in
///     for try await event in connection.chainSync.follow() { … }
/// }
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
        LoggerFactory.configure(config.logging)
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
        LoggerFactory.configure(config.logging)
        let conn = config.connection
        let proto = config.`protocol`

        let (channel, demux) = try await TCPTransport(
            config: conn,
            protocolConfig: proto,
            group: group
        ).connect()

        let connection = NodeToNodeConnection(channel: channel, demux: demux, protocolConfig: proto)
        _ = try await HandshakeClient(
            channel: channel,
            demux: demux,
            config: proto,
            mode: .nodeToNode
        ).negotiate(networkMagic: conn.networkMagic)

        return connection
    }

    // MARK: - Scoped NtC

    /// Open a Node-to-Client connection, run `body`, then close the connection —
    /// even if `body` throws.
    ///
    /// This is the preferred way to use a connection when you want automatic
    /// resource management, analogous to a `with` statement in other languages:
    ///
    /// ```swift
    /// try await CardanoNode.withClient(config: config) { connection in
    ///     for try await event in connection.follow() { … }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - config: Full connection/protocol configuration.
    ///   - group: The NIO event-loop group to use.
    ///   - body: A closure that receives the ready-to-use connection.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `connectToClient` or `body`.
    @discardableResult
    public static func withClient<Result: Sendable>(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        body: @Sendable (NodeToClientConnection) async throws -> Result
    ) async throws -> Result {
        let connection = try await connectToClient(config: config, group: group)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    // MARK: - Scoped NtN

    /// Open a Node-to-Node connection, run `body`, then close the connection —
    /// even if `body` throws.
    ///
    /// This is the preferred way to use a connection when you want automatic
    /// resource management, analogous to a `with` statement in other languages:
    ///
    /// ```swift
    /// try await CardanoNode.withNode(config: .mainnet) { connection in
    ///     for try await event in connection.chainSync.followTyped() { … }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - config: Full connection/protocol configuration.
    ///   - group: The NIO event-loop group to use.
    ///   - body: A closure that receives the ready-to-use connection.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `connectToNode` or `body`.
    @discardableResult
    public static func withNode<Result: Sendable>(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        body: @Sendable (NodeToNodeConnection) async throws -> Result
    ) async throws -> Result {
        let connection = try await connectToNode(config: config, group: group)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    // MARK: - Handshake-less factories (dummy protocols, §3.5)
    //
    // The dummy mini-protocols (Ping-Pong, Request-Response) do not require
    // a handshake. These factories skip the Handshake negotiation entirely
    // and, for NtN, do not start the KeepAlive probe loop either. They are
    // intended for demos, integration tests, and pipelines that speak only
    // dummy protocols — not for talking to a production `cardano-node`.

    /// Connect to a local peer over a Unix domain socket **without** performing
    /// the NtC Handshake.
    ///
    /// The returned `NodeToClientConnection` exposes all mini-protocol clients,
    /// but only the dummy protocols (Ping-Pong, Request-Response) are guaranteed
    /// to work if the remote has not also negotiated a protocol version.
    ///
    /// - Parameters:
    ///   - config: Connection/protocol configuration. `socketPath` must be set.
    ///   - group: NIO event-loop group. Defaults to the process-wide singleton.
    /// - Returns: A `NodeToClientConnection` ready for dummy-protocol traffic.
    /// - Throws: `TransportError.missingSocketPath` if no socket path is
    ///   configured, or an NIO error if the socket is unreachable.
    public static func connectToClientWithoutHandshake(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> NodeToClientConnection {
        let (channel, demux) = try await UnixSocketTransport(
            config: config.connection,
            protocolConfig: config.`protocol`,
            group: group
        ).connect()

        return NodeToClientConnection(channel: channel, demux: demux)
    }

    /// Connect to a remote peer over TCP **without** performing the NtN
    /// Handshake and **without** starting the KeepAlive probe loop.
    ///
    /// The returned `NodeToNodeConnection` exposes all mini-protocol clients,
    /// but only the dummy protocols (Ping-Pong, Request-Response) are guaranteed
    /// to work if the remote has not also negotiated a protocol version.
    ///
    /// - Parameters:
    ///   - config: Connection/protocol configuration. `host` and `port` must be set.
    ///   - group: NIO event-loop group. Defaults to the process-wide singleton.
    /// - Returns: A `NodeToNodeConnection` ready for dummy-protocol traffic.
    /// - Throws: An NIO connection error if the host is unreachable.
    public static func connectToNodeWithoutHandshake(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> NodeToNodeConnection {
        let (channel, demux) = try await TCPTransport(
            config: config.connection,
            protocolConfig: config.`protocol`,
            group: group
        ).connect()

        return NodeToNodeConnection(
            channel: channel,
            demux: demux,
            protocolConfig: config.`protocol`,
            startKeepAlive: false
        )
    }

    /// Scoped NtC variant of `connectToClientWithoutHandshake(config:group:)`.
    ///
    /// Opens the connection, runs `body`, then closes the connection — even if
    /// `body` throws.
    @discardableResult
    public static func withClientWithoutHandshake<Result: Sendable>(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        body: @Sendable (NodeToClientConnection) async throws -> Result
    ) async throws -> Result {
        let connection = try await connectToClientWithoutHandshake(config: config, group: group)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Scoped NtN variant of `connectToNodeWithoutHandshake(config:group:)`.
    ///
    /// Opens the connection, runs `body`, then closes the connection — even if
    /// `body` throws.
    @discardableResult
    public static func withNodeWithoutHandshake<Result: Sendable>(
        config: CardanoNetworkConfiguration = .init(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        body: @Sendable (NodeToNodeConnection) async throws -> Result
    ) async throws -> Result {
        let connection = try await connectToNodeWithoutHandshake(config: config, group: group)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }
}
