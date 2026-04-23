import Logging
import NIOCore

/// Runs the Request-Response mini-protocol (dummy protocol, §3.5.2) from the
/// client (initiator) side.
///
/// Request-Response is a polymorphic request/reply protocol. The client
/// supplies a `ReqRespCodec` that knows how to encode and decode the payload
/// types. It is not part of the Node-to-Node or Node-to-Client protocol
/// suites.
///
/// ## Usage
///
/// ```swift
/// let client = ReqRespClient<ByteBuffer, ByteBuffer>(
///     channel: channel,
///     demux: demux,
///     codec: ReqRespCodec.raw()
/// )
///
/// var requestBuf = channel.allocator.buffer(capacity: 4)
/// requestBuf.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
///
/// let response = try await client.request(requestBuf)
/// try await client.done()
/// ```
public struct ReqRespClient<Request: Sendable, Response: Sendable>: Sendable {

    private let channel: Channel
    private let demux: DemuxHandler
    private let codec: ReqRespCodec<Request, Response>
    private let logger: Logger

    public init(
        channel: Channel,
        demux: DemuxHandler,
        codec: ReqRespCodec<Request, Response>,
        logger: Logger = LoggerFactory.logger(subsystem: "reqResp")
    ) {
        self.channel = channel
        self.demux = demux
        self.codec = codec
        self.logger = logger
    }

    // MARK: - Public API

    /// Send `request` and await the matching `response`.
    ///
    /// State transitions: `idle → busy → idle`.
    public func request(_ request: Request) async throws -> Response {
        let driver = makeDriver()

        logger.debug("ReqResp: sending request")
        try await driver.send(.request(request)) { state in
            guard let s = state as? ReqRespState else { return state }
            return try s.afterSend(ReqRespMessage<Request, Response>.request(request))
        }

        let message = try await driver.receive { msg, state in
            guard let s = state as? ReqRespState else { return state }
            return try s.afterReceive(msg)
        }

        switch message {
        case .response(let resp):
            logger.debug("ReqResp: received response")
            return resp
        default:
            throw ProtocolError.invalidTransition(
                protocol: "reqResp",
                state: "busy",
                message: String(describing: message)
            )
        }
    }

    /// Terminate the protocol without sending any further requests.
    ///
    /// Must be called while the local side holds agency (state `idle`).
    public func done() async throws {
        let driver = makeDriver()
        logger.debug("ReqResp: sending done")
        try await driver.send(.done) { state in
            guard let s = state as? ReqRespState else { return state }
            return try s.afterSend(ReqRespMessage<Request, Response>.done)
        }
    }

    // MARK: - Private

    private func makeDriver() -> ProtocolDriver<ReqRespCodec<Request, Response>> {
        let stream = demux.register(protocolID: MuxSDU.ProtocolID.reqResp)
        return ProtocolDriver(
            channel: channel,
            codec: codec,
            protocolID: MuxSDU.ProtocolID.reqResp,
            initialState: ReqRespState.idle,
            inboundStream: stream,
            protocolName: "reqResp",
            logger: logger
        )
    }
}
