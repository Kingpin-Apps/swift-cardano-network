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

private let alloc = ByteBufferAllocator()

private func rawBuf(_ bytes: [UInt8]) -> ByteBuffer {
    var buf = alloc.buffer(capacity: bytes.count)
    buf.writeBytes(bytes)
    return buf
}

// MARK: - Integration Suite

@Suite("ReqResp integration", .serialized)
struct ReqRespIntegrationTests {

    @Test("ReqResp: default mock echoes the request verbatim")
    func echoRequest() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = ReqRespClient<ByteBuffer, ByteBuffer>(
            channel: channel,
            demux: demux,
            codec: ReqRespCodec.raw(),
            logger: Logger(label: "test.reqresp")
        )

        let request = rawBuf([0xDE, 0xAD, 0xBE, 0xEF])
        let response = try await client.request(request)

        let expected: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let received = response.getBytes(at: response.readerIndex, length: response.readableBytes)
        #expect(received == expected)

        try? await channel.close()
        try? await node.stop()
    }

    @Test("ReqResp: custom handler transforms the request")
    func customHandler() async throws {
        var config = MockNodeConfig()
        config.reqRespHandler = { @Sendable request in
            var resp = ByteBufferAllocator().buffer(capacity: request.readableBytes)
            let bytes =
                request.getBytes(
                    at: request.readerIndex, length: request.readableBytes) ?? []
            resp.writeBytes(bytes.reversed())
            return resp
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(config: config, group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = ReqRespClient<ByteBuffer, ByteBuffer>(
            channel: channel,
            demux: demux,
            codec: ReqRespCodec.raw()
        )

        let request = rawBuf([0x01, 0x02, 0x03])
        let response = try await client.request(request)

        let received = response.getBytes(at: response.readerIndex, length: response.readableBytes)
        #expect(received == [0x03, 0x02, 0x01])

        try? await channel.close()
        try? await node.stop()
    }

    @Test("ReqResp: multiple sequential requests each return their echo")
    func multipleSequentialRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownEventLoopGroup(group) }

        let node = try await MockCardanoNode(group: group)

        let (channel, demux) = try await connectAndHandshake(port: node.port, group: group)

        let client = ReqRespClient<ByteBuffer, ByteBuffer>(
            channel: channel,
            demux: demux,
            codec: ReqRespCodec.raw()
        )

        for i in UInt8(0)..<3 {
            let request = rawBuf([i, i, i])
            let response = try await client.request(request)
            let bytes = response.getBytes(
                at: response.readerIndex, length: response.readableBytes)
            #expect(bytes == [i, i, i])
        }

        try? await channel.close()
        try? await node.stop()
    }
}
