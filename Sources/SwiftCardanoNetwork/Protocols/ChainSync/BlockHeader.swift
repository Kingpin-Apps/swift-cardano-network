import Foundation
import NIOCore
import SwiftCardanoCore

// MARK: - Header NtN wire decoding

extension Header {

    /// Decode a `Header` from the NtN ChainSync wire format stored in a `RawBlock`.
    ///
    /// NtN ChainSync delivers only block headers. The wire format wraps the header as
    /// `[era, #6.24(header_bytes)]` inside an outer protocol envelope, producing two
    /// observed formats inside `rawBlock.rawCBOR`:
    ///
    /// **Format A** — directly `[header_body(14/15 elements), kes_sig]`:
    /// ```
    /// [header_body, kes_sig]
    /// ```
    /// **Format B** — era-prefixed content (as seen from real nodes):
    /// ```
    /// [[era, #6.24(header_cbor_bytes)], kes_sig]
    /// ```
    /// In Format B the inner `#6.24(header_cbor_bytes)` is decoded to reach the final
    /// `[header_body, kes_sig]` array, which is then passed to `Header.fromCBOR`.
    ///
    /// - Throws: `BlockHeaderError` or `CBORError` if the bytes cannot be parsed,
    ///   or `CardanoCoreError` if the decoded header body is invalid.
    init(rawBlock: RawBlock) throws {        
        var buf = rawBlock.rawCBOR

        let outerCount = try CBORLite.readArrayHeader(from: &buf)
        guard outerCount == 2 else {
            throw BlockHeaderError.unexpectedStructure(
                "Expected 2-element outer array, got \(outerCount)")
        }

        guard let firstMajor = CBORLite.peekMajorType(from: buf) else {
            throw CBORError.truncated
        }

        if firstMajor == CBORLite.majorArray {
            let innerCount = try CBORLite.readArrayHeader(from: &buf)

            if innerCount == 2 {
                // Format B — 2-element inner array: [era_or_discriminant, payload]
                let innerFirst = try CBORLite.readUInt(from: &buf)

                guard let innerSecondMajor = CBORLite.peekMajorType(from: buf) else {
                    throw CBORError.truncated
                }

                if innerSecondMajor == 0 {
                    // Byron NtN header: [[discriminant, epochOrSlot], tag24(head_bytes)]
                    // discriminant 0 = EBB, discriminant 1 = BFT main block.
                    // Byron headers cannot be decoded as a Shelley+ `Header` — use
                    // `RawBlock.decodeEra()` which returns an `EraBlock.byron(ByronBlock)`
                    // with all fields parsed (prevHash, epoch, issuerVKey, difficulty, etc).
                    throw BlockHeaderError.byronHeaderNotSupported(discriminant: innerFirst)
                } else {
                    // Shelley+: inner[1] is the header content (tag24 or raw bytes).
                    let headerData = try Header.readHeaderBytes(from: &buf)
                    self = try Header.fromCBOR(data: headerData)
                }
            } else {
                // Format A — innerCount is the header_body field count.
                // Reconstruct a byte buffer for the full [header_body, kes_sig] pair.
                // Re-wind and take all remaining bytes for re-decoding via PotentCBOR.
                let headerData = Data(rawBlock.rawCBOR.readableBytesView)
                self = try Header.fromCBOR(data: headerData)
            }
        } else {
            // Format A with non-array first element — decode the full buffer.
            let headerData = Data(rawBlock.rawCBOR.readableBytesView)
            self = try Header.fromCBOR(data: headerData)
        }
    }

    // MARK: - Private helpers

    /// Read header bytes from the current buffer position, handling tag-24,
    /// raw byte-string, or a directly-embedded CBOR value.
    private static func readHeaderBytes(from buf: inout ByteBuffer) throws -> Data {
        guard let major = CBORLite.peekMajorType(from: buf) else {
            throw CBORError.truncated
        }
        switch major {
        case CBORLite.majorTag:
            let tagNum = try CBORLite.readTag(from: &buf)
            guard tagNum == 24 else {
                throw BlockHeaderError.unexpectedStructure(
                    "Expected tag-24 for embedded CBOR, got tag \(tagNum)")
            }
            let innerBuf = try CBORLite.readByteStringBuffer(from: &buf)
            return Data(innerBuf.readableBytesView)
        case CBORLite.majorByteString:
            let innerBuf = try CBORLite.readByteStringBuffer(from: &buf)
            return Data(innerBuf.readableBytesView)
        default:
            let valueBuf = try CBORLite.readValueBuffer(from: &buf)
            return Data(valueBuf.readableBytesView)
        }
    }
}

// MARK: - EraBlockHeader NtN wire decoding

extension EraBlockHeader {

    /// Decode an `EraBlockHeader` from the NtN ChainSync wire format stored in a `RawBlock`.
    ///
    /// Dispatches by `rawBlock.era`:
    /// - **Era 0 (Byron)**: parses `[[discriminant, epochOrSlot], #6.24(head_bytes)]`
    ///   and returns `.byron(.ebb(_))` or `.byron(.bft(_))`.
    /// - **Eras 1–6 (Shelley+)**: delegates to `Header(rawBlock:)` and wraps in the
    ///   appropriate era case (`.shelley`, `.allegra`, …, `.conway`).
    ///
    /// - Throws: `BlockHeaderError`, `CBORError`, or `CardanoCoreError` on failure.
    init(rawBlock: RawBlock) throws {
        switch rawBlock.era {
        case 0:
            let data = Data(rawBlock.rawCBOR.readableBytesView)
            self = try EraBlockHeader.fromByronNtNData(data)
        case 1:
            self = .shelley(try Header(rawBlock: rawBlock))
        case 2:
            self = .allegra(try Header(rawBlock: rawBlock))
        case 3:
            self = .mary(try Header(rawBlock: rawBlock))
        case 4:
            self = .alonzo(try Header(rawBlock: rawBlock))
        case 5:
            self = .babbage(try Header(rawBlock: rawBlock))
        case 6:
            self = .conway(try Header(rawBlock: rawBlock))
        default:
            throw BlockHeaderError.unexpectedStructure("Unknown era \(rawBlock.era)")
        }
    }
}

// MARK: - Errors

public enum BlockHeaderError: Error, Sendable {
    case unexpectedStructure(String)
    /// Thrown by `decodeHeader()` when the raw block is a Byron era header.
    /// Byron headers are not representable as a Shelley+ `Header`.
    /// Use `RawBlock.decodeEra()` instead, which returns `EraBlock.byron(_)` with
    /// all fields parsed: `prevHash`, `epoch`, `issuerVKey`, `difficulty`, etc.
    /// - Parameter discriminant: 0 = EBB, 1 = BFT main block.
    case byronHeaderNotSupported(discriminant: UInt64)
}
