import NIOCore
import SwiftCardanoCore

// MARK: - EraBlockEvent

/// A chain event that carries a decoded SwiftCardanoCore `EraBlock` instead of
/// the raw `RawBlock` CBOR buffer.
///
/// Produced by `ChainSyncClient.follow(from:)` on an NtC connection.
///
/// ```swift
/// for try await event in connection.chainSync.follow() {
///     switch event {
///     case .rollForward(let eraBlock, let tip):
///         switch eraBlock {
///         case .byron(let byronBlock):
///             print("Byron block, difficulty: \(byronBlock.difficulty)")
///         case .shelley(let block), .allegra(let block), ...:
///             print("Slot: \(block.header.headerBody.slot)")
///         }
///     case .rollBackward(let point, _):
///         print("Rollback to \(point)")
///     }
/// }
/// ```
public enum EraBlockEvent: CustomStringConvertible, Sendable {
    /// A new block was appended to the chain.
    case rollForward(EraBlock, Tip)
    /// The chain rolled back to the given point.
    case rollBackward(Point, Tip)

    public var description: String {
        switch self {
        case .rollForward(let b, let t):
            return "rollForward(block:\(b), tip:\(t))"
        case .rollBackward(let p, let t):
            return "rollBackward(point:\(p), tip:\(t.point))"
        }
    }
}

// MARK: - EraHeaderEvent

/// A chain event that carries a decoded `EraBlockHeader` instead of
/// the raw `RawBlock` CBOR buffer.
///
/// Produced by `ChainSyncClient.follow(from:)` on an NtN connection.
///
/// ```swift
/// for try await event in connection.chainSync.follow() {
///     switch event {
///     case .rollForward(let eraHeader, let tip):
///         switch eraHeader {
///         case .byron(let byronHeader):
///             print("Byron block, difficulty: \(byronHeader.difficulty)")
///         case .shelley(let header), .allegra(let header), ...:
///             print("Slot: \(header.headerBody.slot)")
///         }
///     case .rollBackward(let point, _):
///         print("Rollback to \(point)")
///     }
/// }
/// ```
public enum EraHeaderEvent: CustomStringConvertible, Sendable {
    /// A new block header was appended to the chain.
    case rollForward(EraBlockHeader, Tip)
    /// The chain rolled back to the given point.
    case rollBackward(Point, Tip)

    public var description: String {
        switch self {
        case .rollForward(let h, let t):
            return "rollForward(header:\(h), tip:\(t))"
        case .rollBackward(let p, let t):
            return "rollBackward(point:\(p), tip:\(t.point))"
        }
    }
}

// MARK: - ChainSyncClient typed streams

extension ChainSyncClient {

    /// Like `follow(from:)` but decodes each `RawBlock` into a typed
    /// SwiftCardanoCore `EraBlock` before yielding the event.
    ///
    /// Use this on an **NtC** connection (`NodeToClientConnection`), which
    /// delivers full blocks. For NtN connections use the other `follow(from:)`.
    ///
    /// Decode failures surface as thrown errors inside the stream; the
    /// underlying raw stream is not reused after a failure.
    ///
    /// ```swift
    /// for try await event in connection.chainSync.follow() {
    ///     if case .rollForward(let eraBlock, let tip) = event {
    ///         print("Transactions: \(eraBlock.block?.transactionBodies.count ?? 0)")
    ///     }
    /// }
    /// ```
    public func follow(
        from points: [Point] = []
    ) -> AsyncThrowingStream<EraBlockEvent, Error> {
        let rawStream: AsyncThrowingStream<ChainEvent, Error> = follow(
            from: points
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in rawStream {
                        switch event {
                        case .rollForward(let rawBlock, let tip):
                            let eraBlock = try rawBlock.decodeEra()
                            continuation.yield(.rollForward(eraBlock, tip))
                        case .rollBackward(let point, let tip):
                            continuation.yield(.rollBackward(point, tip))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Use this on an **NtN** connection (`NodeToNodeConnection`), which
    /// delivers block headers only. For NtC connections use the other `follow(from:)`.
    ///
    /// Byron headers are returned as `.byron(.ebb(_))` or `.byron(.bft(_))` with
    /// all fields parsed. Shelley+ headers are returned as `.shelley(header)`, etc.
    ///
    /// Decode failures surface as thrown errors inside the stream; the
    /// underlying raw stream is not reused after a failure.
    ///
    /// ```swift
    /// for try await event in connection.chainSync.follow() {
    ///     if case .rollForward(let eraHeader, let tip) = event {
    ///         if let header = eraHeader.header {
    ///             print("Slot: \(header.headerBody.slot)")
    ///         } else if case .byron(let byronHeader) = eraHeader {
    ///             print("Byron, difficulty: \(byronHeader.difficulty)")
    ///         }
    ///     }
    /// }
    /// ```
    public func follow(
        from points: [Point] = []
    ) -> AsyncThrowingStream<EraHeaderEvent, Error> {
        let rawStream: AsyncThrowingStream<ChainEvent, Error> = follow(
            from: points
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in rawStream {
                        switch event {
                        case .rollForward(let rawBlock, let tip):
                            let eraHeader = try rawBlock.decodeEraHeader()
                            continuation.yield(.rollForward(eraHeader, tip))
                        case .rollBackward(let point, let tip):
                            continuation.yield(.rollBackward(point, tip))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
