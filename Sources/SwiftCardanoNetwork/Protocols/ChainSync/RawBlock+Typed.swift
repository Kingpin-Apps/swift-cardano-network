import Foundation
import NIOCore
import SwiftCardanoCore

extension RawBlock {

    /// Decode this raw CBOR block into a fully-typed SwiftCardanoCore `Block`.
    ///
    /// Use this on an **NtC** connection, which delivers full Shelley+ block bodies
    /// as a 5-element CBOR array `[header, bodies, witnessSets, auxiliaryData, invalidTxIndices]`.
    ///
    /// For era-aware decoding (including Byron) use `decodeEra()`.
    ///
    /// - Throws: `CardanoCoreError.deserializeError` if the bytes are not a valid block.
    public func decode() throws -> Block {
        let data = Data(rawCBOR.readableBytesView)
        return try Block.fromCBOR(data: data)
    }

    /// Decode this raw CBOR block into an era-tagged `EraBlock`.
    ///
    /// Works for all eras including Byron. The `era` field on `RawBlock` is used
    /// to dispatch to the correct decoder; `rawCBOR` must contain the unwrapped
    /// block bytes (tag-24 already stripped by the codec).
    ///
    /// - Throws: `CardanoCoreError.deserializeError` if the bytes cannot be parsed.
    public func decodeEra() throws -> EraBlock {
        let data = Data(rawCBOR.readableBytesView)
        return try EraBlock.fromBlockCBOR(data: data, era: era)
    }

    /// Decode this raw CBOR header into a typed `Header` from SwiftCardanoCore.
    ///
    /// Use this on an **NtN** connection, which delivers block headers only.
    /// Real Cardano nodes send NtN headers in a nested format:
    /// `[[era, #6.24(header_bytes)], kes_sig]`. This method handles both that
    /// format and the direct `[header_body, kes_sig]` format.
    ///
    /// Byron headers (era 0) cannot be decoded as a typed `Header` and will throw
    /// `BlockHeaderError.byronHeaderNotSupported`. Use `decodeEraHeader()` instead,
    /// which returns an `EraBlockHeader` covering all eras including Byron.
    ///
    /// - Throws: `BlockHeaderError`, `CBORError`, or `CardanoCoreError` on failure.
    public func decodeHeader() throws -> Header {
        return try Header(rawBlock: self)
    }

    /// Decode this raw CBOR header into an era-tagged `EraBlockHeader`.
    ///
    /// Works for all eras including Byron. For era 0, returns
    /// `.byron(.ebb(_))` or `.byron(.bft(_))` with all fields parsed. For eras
    /// 1–6 (Shelley+), returns the appropriate typed `Header` wrapped in the
    /// matching era case.
    ///
    /// Use this on an **NtN** connection (`NodeToNodeConnection`).
    ///
    /// - Throws: `BlockHeaderError`, `CBORError`, or `CardanoCoreError` on failure.
    public func decodeEraHeader() throws -> EraBlockHeader {
        return try EraBlockHeader(rawBlock: self)
    }
}
