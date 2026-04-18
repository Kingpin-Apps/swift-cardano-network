import NIOCore

// MARK: - BlockFetch messages

/// The complete BlockFetch mini-protocol message set (NtN only, protocol ID 3).
///
/// BlockFetch is a separate protocol from ChainSync in the NtN stack. ChainSync
/// delivers block *headers*; BlockFetch downloads the corresponding block *bodies*.
///
/// ## Wire tags
/// ```
/// msgRequestRange = [0, point, point]
/// msgClientDone   = [1]
/// msgStartBatch   = [2]
/// msgNoBlocks     = [3]
/// msgBlock        = [4, #6.24(bstr)]   ; tag 24 = embedded CBOR
/// msgBatchDone    = [5]
/// ```
public enum BlockFetchMessage: Sendable {
    // Client → Server
    /// Request all blocks in the half-open range `(from, to]`.
    case requestRange(from: Point, to: Point)
    /// Signal that the client is done and will send no more requests.
    case clientDone

    // Server → Client
    /// The server will stream the requested blocks.
    case startBatch
    /// No blocks exist in the requested range.
    case noBlocks
    /// A single block body (raw CBOR; decode with `swift-cardano-core`).
    case block(ByteBuffer)
    /// All blocks in the batch have been sent.
    case batchDone
}

// MARK: - Error types

public enum BlockFetchError: Error, Sendable {
    case unknownMessageTag(UInt64)
    case unexpectedArrayLength(Int)
    case malformedPoint(arrayLength: Int)
    case emptyBatch
}
