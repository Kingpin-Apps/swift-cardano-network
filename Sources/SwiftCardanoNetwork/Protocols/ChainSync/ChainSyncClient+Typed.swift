import NIOCore
import SwiftCardanoCore

// MARK: - TypedChainEvent

/// A chain event that carries a decoded SwiftCardanoCore `Block` instead of
/// the raw `RawBlock` CBOR buffer.
///
/// Produced by `ChainSyncClient.followTyped(from:)`.
public enum TypedChainEvent: Sendable {
    /// A new block was appended to the chain.
    case rollForward(Block, Tip)
    /// The chain rolled back to the given point.
    case rollBackward(Point, Tip)
}

// MARK: - ChainSyncClient typed stream

extension ChainSyncClient {

    /// Like `follow(from:)` but decodes each `RawBlock` into a typed
    /// SwiftCardanoCore `Block` before yielding the event.
    ///
    /// Decode failures surface as thrown errors inside the stream; the
    /// underlying raw stream is not reused after a failure.
    ///
    /// ```swift
    /// for try await event in connection.chainSync.followTyped() {
    ///     if case .rollForward(let block, let tip) = event {
    ///         print("Transactions: \(block.transactionBodies.count)")
    ///     }
    /// }
    /// ```
    public func followTyped(
        from points: [Point] = []
    ) -> AsyncThrowingStream<TypedChainEvent, Error> {
        let rawStream = follow(from: points)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in rawStream {
                        switch event {
                        case .rollForward(let rawBlock, let tip):
                            let block = try rawBlock.decode()
                            continuation.yield(.rollForward(block, tip))
                        case .rollBackward(let point, let tip):
                            continuation.yield(.rollBackward(point, tip))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
