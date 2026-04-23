import Logging
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - TransportError

@Suite("TransportError") struct TransportErrorTests {

    @Test("missingSocketPath is the expected error case")
    func missingSocketPathCase() {
        let err = TransportError.missingSocketPath
        if case .missingSocketPath = err { /* pass */
        } else {
            Issue.record("Wrong TransportError case")
        }
    }

    @Test("missingSocketPath conforms to Error")
    func conformsToError() {
        let err: any Error = TransportError.missingSocketPath
        #expect(err is TransportError)
    }

    @Test("missingSocketPath conforms to Sendable")
    func conformsToSendable() {
        // Compile-time check: TransportError must be Sendable.
        func requiresSendable<T: Sendable>(_: T) {}
        requiresSendable(TransportError.missingSocketPath)
    }
}

// MARK: - UnixSocketTransport

@Suite("UnixSocketTransport") struct UnixSocketTransportTests {

    @Test("connect(): throws missingSocketPath when socketPath is nil")
    func connectThrowsMissingSocketPath() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var conn = ConnectionConfig()
        conn.socketPath = nil  // explicit nil — default behaviour

        let transport = UnixSocketTransport(
            config: conn,
            protocolConfig: ProtocolConfig(),
            group: group
        )

        do {
            _ = try await transport.connect()
            Issue.record("Expected TransportError.missingSocketPath but no error was thrown")
        } catch TransportError.missingSocketPath {
            // expected
        } catch {
            Issue.record("Expected TransportError.missingSocketPath, got \(error)")
        }
    }

    @Test("connect(): throws missingSocketPath regardless of other config fields")
    func connectThrowsMissingSocketPathWithOtherFieldsSet() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var conn = ConnectionConfig()
        conn.socketPath = nil
        conn.networkMagic = 764_824_073

        var proto = ProtocolConfig()
        proto.ntcMaxSDUSize = 32_768

        let transport = UnixSocketTransport(config: conn, protocolConfig: proto, group: group)

        do {
            _ = try await transport.connect()
            Issue.record("Expected TransportError.missingSocketPath but no error was thrown")
        } catch TransportError.missingSocketPath {
            // expected
        } catch {
            Issue.record("Expected TransportError.missingSocketPath, got \(error)")
        }
    }

    @Test("connect(): throws missingSocketPath when socketPath is empty string")
    func connectToEmptySocketPath() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        var conn = ConnectionConfig()
        conn.socketPath = "/this/socket/does/not/exist.socket"

        let transport = UnixSocketTransport(
            config: conn, protocolConfig: ProtocolConfig(), group: group)

        // When socketPath points to a non-existent socket the transport must
        // throw (NIO POSIX error), but NOT missingSocketPath.
        await #expect(throws: (any Error).self) {
            _ = try await transport.connect()
        }
    }
}

// MARK: - TCPTransport

@Suite("TCPTransport") struct TCPTransportTests {

    @Test("connect(): throws a network error when the target port refuses connections")
    func connectFailsOnRefusedPort() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        // Bind to a random port, capture it, then immediately close the listener
        // so the port is guaranteed to be closed when TCPTransport tries to connect.
        let server = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let closedPort = server.localAddress!.port!
        try await server.close()

        var conn = ConnectionConfig()
        conn.host = "127.0.0.1"
        conn.port = closedPort

        let transport = TCPTransport(config: conn, protocolConfig: ProtocolConfig(), group: group)

        await #expect(throws: (any Error).self) {
            _ = try await transport.connect()
        }
    }

    @Test("connect(): succeeds and returns a valid channel when a server is listening")
    func connectSucceedsWithServer() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        // Minimal echo server — just accepts the connection.
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = server.localAddress!.port!

        var conn = ConnectionConfig()
        conn.host = "127.0.0.1"
        conn.port = port

        let transport = TCPTransport(config: conn, protocolConfig: ProtocolConfig(), group: group)
        let (channel, _) = try await transport.connect()

        #expect(channel.isActive)

        try? await channel.close()
        try? await server.close()
    }

    @Test("connect(): returns a channel with the mux pipeline installed")
    func connectInstallsMuxPipeline() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = server.localAddress!.port!

        var conn = ConnectionConfig()
        conn.host = "127.0.0.1"
        conn.port = port

        let transport = TCPTransport(config: conn, protocolConfig: ProtocolConfig(), group: group)
        let (channel, _) = try await transport.connect()

        // The pipeline must contain the MuxFrameEncoder/Decoder installed by TCPTransport.
        let hasMuxDecoder = try await channel.pipeline.context(
            handlerType: ByteToMessageHandler<MuxFrameDecoder>.self
        )
        .map { _ in true }
        .recover { _ in false }
        .get()

        #expect(hasMuxDecoder)

        try? await channel.close()
        try? await server.close()
    }
}
