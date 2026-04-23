import Logging
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

/// Connect to `port`, complete the NtN handshake, and return `(channel, demux)`.
///
/// The mock server's dummy-protocol handlers only start after the handshake
/// completes, so we negotiate it explicitly here.
private func connectAndHandshake(
    port: Int,
    group: EventLoopGroup
) async throws -> (Channel, DemuxHandler) {
    var conn = ConnectionConfig()
    conn.host = "127.0.0.1"
    conn.port = port

    let (channel, demux) = try await TCPTransport(
        config: conn,
        protocolConfig: ProtocolConfig(),
        group: group
    ).connect()

    _ = try await HandshakeClient(
        channel: channel,
        demux: demux,
        config: ProtocolConfig(),
        mode: .nodeToNode
    ).negotiate(networkMagic: 764_824_073)

    return (channel, demux)
}

// MARK: - Integration Suite

@Suite("PingPong integration", .serialized)
struct PingPongIntegrationTests {

    @Test("PingPong: single ping receives matching pong")
    func singlePingPong() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = PingPongClient(
            channel: channel,
            demux: demux,
            logger: Logger(label: "test.pingpong")
        )
        try await client.ping()
        // No throw → pong was received in the expected state.

        try? await channel.close()
        try? await node.stop()
    }

    @Test("PingPong: run(count:) executes N round-trips and terminates cleanly")
    func multipleRoundTrips() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = PingPongClient(
            channel: channel,
            demux: demux,
            logger: Logger(label: "test.pingpong")
        )
        try await client.run(count: 5)

        try? await channel.close()
        try? await node.stop()
    }

    @Test("PingPong: zero-count run only sends done")
    func zeroCountRun() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = PingPongClient(
            channel: channel,
            demux: demux,
            logger: Logger(label: "test.pingpong")
        )
        try await client.run(count: 0)

        try? await channel.close()
        try? await node.stop()
    }
}
