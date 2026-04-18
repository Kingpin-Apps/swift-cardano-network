import NIOCore
import SwiftCardanoCore

// MARK: - Primitive types

/// A raw, CBOR-encoded Cardano transaction with its era tag.
///
/// `rawCBOR` is the serialised transaction body. Use `swift-cardano-core` to produce this value.
public struct RawTransaction: @unchecked Sendable {
    public let era: Era
    public var rawCBOR: ByteBuffer

    public init(era: Era, rawCBOR: ByteBuffer) {
        self.era = era
        self.rawCBOR = rawCBOR
    }
}

/// An era-tagged transaction rejection returned by the node.
///
/// `era` identifies which era's validation rules rejected the transaction.
/// Decode `reasonCBOR` with `swift-cardano-core` to obtain typed rejection details
/// (e.g. `BadInputs`, `InsufficientFee`, `ScriptFailure`).
public struct TxRejection: @unchecked Sendable {
    public let era: Era
    public var reasonCBOR: ByteBuffer

    public init(era: Era, reasonCBOR: ByteBuffer) {
        self.era = era
        self.reasonCBOR = reasonCBOR
    }
}

// MARK: - Protocol messages

/// The complete LocalTxSubmission mini-protocol message set (NtC only).
public enum LocalTxSubmissionMessage: Sendable {
    // Client → Server
    case submitTx(RawTransaction)
    case done

    // Server → Client
    case acceptTx
    case rejectTx(TxRejection)
}

// MARK: - Errors

public enum LocalTxSubmissionError: Error, Sendable {
    /// The node rejected the transaction. Inspect `TxRejection.reasonCBOR` for the error detail.
    case rejected(TxRejection)
    /// The CBOR message tag was not one of 0–3.
    case unknownMessageTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
    /// The era wire tag received from the node does not correspond to a known era.
    case unknownEraTag(UInt16)
}
