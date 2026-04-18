import Foundation
import Logging
import NIOCore

/// Routes inbound `MuxSDU` frames to per-protocol `AsyncStream` consumers.
///
/// `register(protocolID:)` may be called at any time — including after the
/// channel is active — because each protocol client creates its driver lazily
/// on first use.  A `NIOLock` serialises all reads and writes to the
/// `registrations` dictionary so concurrent calls from the Swift concurrency
/// executor and the NIO event-loop thread cannot race.
public final class DemuxHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = MuxSDU
    public typealias InboundOut = Never

    private let lock = NSLock()
    private var registrations: [UInt16: AsyncStream<MuxSDU>.Continuation] = [:]
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Registration

    /// Register interest in a mini-protocol. Returns an `AsyncStream` that yields
    /// each inbound `MuxSDU` destined for `protocolID`.
    ///
    /// Safe to call before or after the channel becomes active.
    public func register(protocolID: UInt16) -> AsyncStream<MuxSDU> {
        var stored: AsyncStream<MuxSDU>.Continuation?
        let stream = AsyncStream<MuxSDU> { cont in stored = cont }
        lock.withLock { registrations[protocolID] = stored }
        return stream
    }

    // MARK: - ChannelInboundHandler

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let sdu = unwrapInboundIn(data)
        let protoID = sdu.miniProtocolID

        let continuation = lock.withLock { registrations[protoID] }
        guard let continuation else {
            logger.warning("Unknown protocol ID in SDU", metadata: ["protocolID": "\(protoID)"])
            return
        }
        continuation.yield(sdu)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        // Drain and clear under the lock, then signal outside it so that
        // continuation callbacks cannot re-enter the lock.
        let conts = lock.withLock { () -> [AsyncStream<MuxSDU>.Continuation] in
            let values = Array(registrations.values)
            registrations.removeAll()
            return values
        }
        for continuation in conts {
            continuation.finish()
        }
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error in DemuxHandler", metadata: ["error": "\(error)"])
        context.fireErrorCaught(error)
    }
}
