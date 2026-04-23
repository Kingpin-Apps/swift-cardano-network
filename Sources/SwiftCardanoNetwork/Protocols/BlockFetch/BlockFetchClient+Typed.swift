import Foundation
import NIOCore
import SwiftCardanoCore

// MARK: - BlockFetchClient typed API

extension BlockFetchClient {

    /// Download all block bodies in the range `[from, to]` and decode each into
    /// a typed SwiftCardanoCore `EraBlock`.
    ///
    /// Equivalent to `fetch(from:to:)` but decodes the raw CBOR returned by the
    /// node into era-tagged block values.  Use this on an **NtN** connection where
    /// the node returns era-tagged block bodies.
    ///
    /// Each `ByteBuffer` delivered by the node is encoded as:
    /// ```
    /// [era, #6.24(block_cbor)]   ; Shelley+
    /// [era, bstr]                ; Byron / fallback
    /// ```
    /// This method extracts the era and block bytes, then delegates to
    /// `RawBlock.decodeEra()` which calls `EraBlock.fromBlockCBOR(data:era:)`.
    ///
    /// Decode failures surface as thrown errors; the underlying protocol state
    /// is not reused after a failure.
    ///
    /// ```swift
    /// let blocks: [EraBlock] = try await connection.blockFetch.fetch(
    ///     from: .blockPoint(slot: 1_000_000, hash: startHash),
    ///     to:   .blockPoint(slot: 1_001_000, hash: endHash)
    /// )
    /// for block in blocks {
    ///     if case .conway(let b) = block {
    ///         print("Transactions: \(b.transactionBodies.count)")
    ///     }
    /// }
    /// ```
    ///
    /// - Throws: `BlockFetchError.emptyBatch` if the peer has no blocks in
    ///   range, a `BlockFetchDecodeError` if the era-tagged structure is
    ///   malformed, or a `CardanoCoreError` if block CBOR cannot be parsed.
    public func fetch(
        from startPoint: Point,
        to endPoint: Point
    ) async throws -> [EraBlock] {
        let rawBuffers: [ByteBuffer] = try await fetch(from: startPoint, to: endPoint)
        return try rawBuffers.map { try parseEraBlock(from: $0) }
    }

    // MARK: - Private

    /// Parse an era-tagged block buffer `[era, #6.24(block_bytes)]` into a `RawBlock`
    /// and decode it into an `EraBlock`.
    ///
    /// This mirrors the logic in `ChainSyncCodec.readWrappedBlock`.
    private func parseEraBlock(from buffer: ByteBuffer) throws -> EraBlock {
        var buf = buffer

        let arrayLen = try CBORLite.readArrayHeader(from: &buf)
        guard arrayLen == 2 else {
            throw BlockFetchDecodeError.unexpectedEraWrapperLength(arrayLen)
        }

        let era = try CBORLite.readUInt(from: &buf)

        // The block content may be tag-24 wrapped (Shelley+) or a raw byte string (Byron).
        let rawCBOR: ByteBuffer
        if let major = CBORLite.peekMajorType(from: buf), major == CBORLite.majorTag {
            let tagNum = try CBORLite.readTag(from: &buf)
            if tagNum == 24 {
                rawCBOR = try CBORLite.readByteStringBuffer(from: &buf)
            } else {
                // Unknown tag — skip and take remaining bytes.
                try CBORLite.skipValue(in: &buf)
                rawCBOR = buf
            }
        } else {
            // Plain byte string (Byron / fallback).
            rawCBOR = buf
        }

        let rawBlock = RawBlock(era: era, rawCBOR: rawCBOR)
        return try rawBlock.decodeEra()
    }
}

// MARK: - Errors

/// Errors raised when decoding an era-tagged BlockFetch block body.
public enum BlockFetchDecodeError: Error, Sendable {
    /// The outer CBOR array had an unexpected number of elements (expected 2).
    case unexpectedEraWrapperLength(Int)
}
