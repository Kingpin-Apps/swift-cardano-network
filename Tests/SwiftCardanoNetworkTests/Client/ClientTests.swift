import Logging
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let logger = Logger(label: "test.client")

/// Creates a NIOAsyncTestingChannel with a DemuxHandler in the pipeline.
/// NIOAsyncTestingChannel uses a lock-based event loop, making it safe to
/// access from any thread — including async continuations and actor executors.
private func makeChannelAndDemux() async throws -> (NIOAsyncTestingChannel, DemuxHandler) {
    let ch = NIOAsyncTestingChannel()
    let demux = DemuxHandler(logger: logger)
    try await ch.pipeline.addHandler(demux)
    return (ch, demux)
}

// MARK: - NodeToClientConnection

@Suite("NodeToClientConnection") @MainActor struct NodeToClientConnectionTests {

    @Test("init: channel property references the provided channel")
    func initStoresChannel() async throws {
        let (ch, demux) = try await makeChannelAndDemux()
        let conn = NodeToClientConnection(channel: ch, demux: demux)
        #expect(conn.channel === ch)
        _ = try? await ch.finish()
    }

    @Test("init: exposes chainSync, txSubmission, stateQuery and txMonitor clients")
    func initExposesProtocolClients() async throws {
        let (ch, demux) = try await makeChannelAndDemux()
        let conn = NodeToClientConnection(channel: ch, demux: demux)
        // Access all four NtC clients; verifies they are created without crashing.
        _ = conn.chainSync
        _ = conn.txSubmission
        _ = conn.stateQuery
        _ = conn.txMonitor
        _ = try? await ch.finish()
    }

    @Test("close(): completes without throwing")
    func closeCompletesCleanly() async throws {
        let (ch, demux) = try await makeChannelAndDemux()
        let conn = NodeToClientConnection(channel: ch, demux: demux)
        await conn.close()
        _ = try? await ch.finish()
    }

    @Test("close(): is idempotent — second call is a no-op")
    func closeIsIdempotent() async throws {
        let (ch, demux) = try await makeChannelAndDemux()
        let conn = NodeToClientConnection(channel: ch, demux: demux)
        await conn.close()
        await conn.close()
        _ = try? await ch.finish()
    }
}

// MARK: - NodeToNodeConnection

@Suite("NodeToNodeConnection") @MainActor struct NodeToNodeConnectionTests {

    /// Builds an NtN connection with a very long KeepAlive interval so the
    /// background probe task stays dormant throughout each test.
    private func makeNtNConnection() async throws -> (NIOAsyncTestingChannel, NodeToNodeConnection)
    {
        let (ch, demux) = try await makeChannelAndDemux()
        var proto = ProtocolConfig()
        proto.keepAliveIntervalSeconds = 3_600  // 1 hour — never fires in tests
        let conn = NodeToNodeConnection(channel: ch, demux: demux, protocolConfig: proto)
        return (ch, conn)
    }

    @Test("init: channel property references the provided channel")
    func initStoresChannel() async throws {
        let (ch, conn) = try await makeNtNConnection()
        #expect(conn.channel === ch)
        await conn.close()
        _ = try? await ch.finish()
    }

    @Test("init: exposes chainSync, blockFetch and txSubmission2 clients")
    func initExposesProtocolClients() async throws {
        let (ch, conn) = try await makeNtNConnection()
        _ = conn.chainSync
        _ = conn.blockFetch
        _ = conn.txSubmission2
        await conn.close()
        _ = try? await ch.finish()
    }

    @Test("close(): cancels the KeepAlive task and closes the channel")
    func closeCompletesCleanly() async throws {
        let (ch, conn) = try await makeNtNConnection()
        await conn.close()
        _ = try? await ch.finish()
    }

    @Test("close(): is idempotent — repeated calls do not throw or hang")
    func closeIsIdempotent() async throws {
        let (ch, conn) = try await makeNtNConnection()
        await conn.close()
        await conn.close()
        _ = try? await ch.finish()
    }
}

// MARK: - CardanoNode

@Suite("CardanoNode") struct CardanoNodeTests {

    // MARK: connectToClient

    @Test("connectToClient: throws missingSocketPath when no socket path is configured")
    func connectToClientMissingSocketPath() async {
        let config = CardanoNetworkConfiguration()
        // socketPath is nil by default in ConnectionConfig.
        #expect(config.connection.socketPath == nil)

        do {
            _ = try await CardanoNode.connectToClient(config: config)
            Issue.record("Expected TransportError.missingSocketPath but no error was thrown")
        } catch TransportError.missingSocketPath {
            // expected
        } catch {
            Issue.record("Expected TransportError.missingSocketPath, got \(error)")
        }
    }

    @Test("connectToClient: throws missingSocketPath even with other config fields set")
    func connectToClientMissingSocketPathWithOtherFields() async {
        var config = CardanoNetworkConfiguration()
        config.connection.networkMagic = 2  // preview
        // socketPath is still nil

        do {
            _ = try await CardanoNode.connectToClient(config: config)
            Issue.record("Expected TransportError.missingSocketPath but no error was thrown")
        } catch TransportError.missingSocketPath {
            // expected
        } catch {
            Issue.record("Expected TransportError.missingSocketPath, got \(error)")
        }
    }

    // MARK: connectToNode

    @Test("connectToNode: throws a network error when the remote port refuses connections")
    func connectToNodeRefusedPort() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        // Bind to a random free port, capture it, then immediately close the server
        // so any subsequent connection attempt receives ECONNREFUSED.
        let server = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let closedPort = server.localAddress!.port!
        try await server.close()

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = closedPort

        await #expect(throws: (any Error).self) {
            _ = try await CardanoNode.connectToNode(config: config, group: group)
        }
    }

    // MARK: connectToNode — with MockCardanoNode (NtN)

    @Test("connectToNode: returns a NodeToNodeConnection on successful handshake")
    func connectToNodeSucceeds() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = node.port

        let conn = try await CardanoNode.connectToNode(config: config, group: group)
        await conn.close()
        try? await node.stop()
    }

    // MARK: withClient

    @Test("withClient: throws missingSocketPath when no socket path is configured")
    func withClientMissingSocketPath() async {
        let config = CardanoNetworkConfiguration()
        do {
            try await CardanoNode.withClient(config: config) { _ in }
            Issue.record("Expected TransportError.missingSocketPath but no error was thrown")
        } catch TransportError.missingSocketPath {
            // expected
        } catch {
            Issue.record("Expected TransportError.missingSocketPath, got \(error)")
        }
    }

    @Test("withClient: body is never executed when the connection fails")
    func withClientBodyNotCalledOnConnectionFailure() async {
        let config = CardanoNetworkConfiguration()
        let _ = try? await CardanoNode.withClient(config: config) { _ in
            Issue.record("Body should not be called when connection fails")
        }
    }

    @Test("withClient: throws missingSocketPath even with other config fields set")
    func withClientMissingSocketPathWithOtherFields() async {
        var config = CardanoNetworkConfiguration()
        config.connection.networkMagic = 2  // preview magic — socket path still nil

        do {
            try await CardanoNode.withClient(config: config) { _ in }
            Issue.record("Expected TransportError.missingSocketPath but no error was thrown")
        } catch TransportError.missingSocketPath {
            // expected
        } catch {
            Issue.record("Expected TransportError.missingSocketPath, got \(error)")
        }
    }

    // MARK: withNode

    @Test("withNode: throws a network error when the remote port refuses connections")
    func withNodeRefusedPort() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let server = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let closedPort = server.localAddress!.port!
        try await server.close()

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = closedPort

        await #expect(throws: (any Error).self) {
            try await CardanoNode.withNode(config: config, group: group) { _ in }
        }
    }

    @Test("withNode: body is never executed when the connection fails")
    func withNodeBodyNotCalledOnConnectionFailure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let server = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let closedPort = server.localAddress!.port!
        try await server.close()

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = closedPort

        let _ = try? await CardanoNode.withNode(config: config, group: group) { _ in
            Issue.record("Body should not be called when connection fails")
        }
    }

    @Test("withNode: returns the value produced by the body")
    func withNodeReturnsBodyValue() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = node.port

        let result = try await CardanoNode.withNode(config: config, group: group) { _ in
            return 42
        }
        #expect(result == 42)
        try? await node.stop()
    }

    @Test("withNode: propagates body errors and closes the connection")
    func withNodePropagatesBodyError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = node.port

        struct SentinelError: Error {}

        do {
            try await CardanoNode.withNode(config: config, group: group) { _ in
                throw SentinelError()
            }
            Issue.record("Expected SentinelError to be rethrown")
        } catch is SentinelError {
            // expected — connection was also closed inside withNode
        } catch {
            Issue.record("Expected SentinelError, got \(error)")
        }
        try? await node.stop()
    }

    @Test("withNode: discardable result — body return value can be ignored")
    func withNodeDiscardableResult() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        var config = CardanoNetworkConfiguration()
        config.connection.host = "127.0.0.1"
        config.connection.port = node.port

        // @discardableResult — no warning when result is dropped
        try await CardanoNode.withNode(config: config, group: group) { _ in
            return "ignored"
        }
        try? await node.stop()
    }
}
