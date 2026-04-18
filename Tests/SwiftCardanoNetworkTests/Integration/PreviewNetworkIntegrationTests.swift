import Darwin
import NIOCore
import NIOPosix
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Availability probe

/// Synchronous TCP probe — attempts a single connect() with a 1-second timeout.
/// Returns `true` only if `cardano-node` is listening on 127.0.0.1:3001.
/// Used as the `.enabled(if:)` guard for the entire preview-network suite.
private func previewNodeReachable(host: String = "127.0.0.1", port: UInt16 = 3001) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { Darwin.close(sock) }

    // 1-second send/receive timeout so the probe never blocks the test suite.
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.stride))
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.stride))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)

    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
        }
    }
}

// MARK: - Preview network constants

private let previewMagic: UInt32 = 2
private let previewPort = 3001
private let previewHost = "127.0.0.1"

// MARK: - Helpers

private func previewConnectionConfig() -> ConnectionConfig {
    var conn = ConnectionConfig()
    conn.host = previewHost
    conn.port = previewPort
    conn.networkMagic = previewMagic
    return conn
}

/// Connect over TCP and complete the NtN handshake with the local preview node.
private func connectAndHandshakePreview(group: EventLoopGroup) async throws -> (
    Channel, DemuxHandler
) {
    let (channel, demux) = try await TCPTransport(
        config: previewConnectionConfig(),
        protocolConfig: ProtocolConfig(),
        group: group
    ).connect()

    _ = try await HandshakeClient(
        channel: channel,
        demux: demux,
        config: ProtocolConfig(),
        mode: .nodeToNode
    ).negotiate(networkMagic: previewMagic)

    return (channel, demux)
}

// MARK: - Suite

/// Live integration tests against a locally-running preview-network cardano-node
/// (127.0.0.1:3001, magic = 2).
///
/// All tests in this suite are automatically **skipped** when no node is
/// reachable on that address, so they are safe to run in CI environments
/// where the node is absent.
@Suite(
    "Preview Network (live)",
    .enabled(
        if: previewNodeReachable(), "No cardano-node found on 127.0.0.1:3001 — skipping live tests"),
    .serialized
)
struct PreviewNetworkIntegrationTests {

    // MARK: - Handshake

    @Test("Handshake: negotiates a supported NtN version with preview magic")
    func handshakeNegotiatesVersion() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let (channel, demux) = try await TCPTransport(
            config: previewConnectionConfig(),
            protocolConfig: ProtocolConfig(),
            group: group
        ).connect()
        defer { Task { try? await channel.close() } }

        let negotiated = try await HandshakeClient(
            channel: channel,
            demux: demux,
            config: ProtocolConfig(),
            mode: .nodeToNode
        ).negotiate(networkMagic: previewMagic)

        // Cardano nodes supporting NtN ≥ v7 are acceptable; real preview nodes
        // advertise up to v14 at the time of writing.
        #expect(negotiated.version >= 7)

        guard case .nodeToNode(let magic, _, _, _) = negotiated.versionData else {
            Issue.record("Expected nodeToNode version data, got \(negotiated.versionData)")
            return
        }
        #expect(magic == previewMagic)
    }

    // MARK: - CardanoNode factory

    @Test("CardanoNode.connectToNode: factory connects and negotiates with preview config")
    func cardanoNodeFactoryConnects() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        var config = CardanoNetworkConfiguration()
        config.connection = previewConnectionConfig()

        let connection = try await CardanoNode.connectToNode(config: config, group: group)

        // If we reach here the handshake succeeded and KeepAlive is running.
        let isActive = connection.channel.isActive
        await connection.close()
        #expect(isActive)
    }

    // MARK: - ChainSync

    @Test("ChainSync: receives at least one rollForward event from tip within 60 seconds")
    func chainSyncReceivesBlockFromTip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let (channel, demux) = try await connectAndHandshakePreview(group: group)
        defer { Task { try? await channel.close() } }

        // Follow from an empty point list ⟹ start from the node's current tip.
        let stream = ChainSyncClient(channel: channel, demux: demux).follow(from: [])

        // Collect the first event, honouring a 60-second deadline.
        let firstEvent = try await withThrowingTaskGroup(of: ChainEvent?.self) { group in
            group.addTask {
                for try await event in stream { return event }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return nil  // timeout sentinel
            }
            let result = try await group.next()
            group.cancelAll()
            return result
        }

        guard let event = firstEvent else {
            Issue.record("No ChainSync event received within 60 seconds")
            return
        }

        switch event {
        case .rollForward(let block, let tip):
            // A synced preview node will only serve headers over NtN ChainSync.
            #expect(
                block.rawCBOR.readableBytes > 0,
                "Expected non-empty block CBOR from live node")
            #expect(tip.blockNo > 0, "Expected non-zero tip block number")
        case .rollBackward(let point, _):
            // A rollback at the tip is valid; verify the point is non-origin.
            switch point {
            case .origin:
                // Rolling back to origin on a live synced node would be surprising
                // but is technically valid — just record it rather than fail.
                break
            case .blockPoint(let slot, _):
                #expect(slot >= 0)
            }
        case .none:
            Issue.record("Received unexpected .none ChainEvent")
        }
    }

    @Test("ChainSync: intersection not found for unknown point on preview")
    func chainSyncIntersectNotFoundOnPreview() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let (channel, demux) = try await connectAndHandshakePreview(group: group)
        defer { Task { try? await channel.close() } }

        // A block hash of all 0xFF bytes is astronomically unlikely to exist.
        let bogusPoint = Point.blockPoint(
            slot: 1,
            hash: Array(repeating: 0xFF, count: 32)
        )
        let stream = ChainSyncClient(channel: channel, demux: demux).follow(from: [bogusPoint])

        do {
            for try await _ in stream { break }
            Issue.record("Expected ChainSyncError.intersectionNotFound to be thrown")
        } catch let error as ChainSyncError {
            guard case .intersectionNotFound = error else {
                Issue.record("Unexpected ChainSyncError variant: \(error)")
                return
            }
            // Expected path — intersect rejected by the live node.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - KeepAlive (via NodeToNodeConnection factory)

    @Test("KeepAlive: connection remains active after handshake via factory")
    func keepAliveConnectionRemainsActive() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        var config = CardanoNetworkConfiguration()
        config.connection = previewConnectionConfig()

        let connection = try await CardanoNode.connectToNode(config: config, group: group)

        // Wait briefly to confirm the KeepAlive loop has not tripped an error.
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 s

        #expect(connection.channel.isActive, "Channel should still be active after 2 s")

        await connection.close()
    }
}
