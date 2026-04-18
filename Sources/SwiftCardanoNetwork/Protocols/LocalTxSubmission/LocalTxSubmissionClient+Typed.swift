import Foundation
import NIOCore
import SwiftCardanoCore

// MARK: - Typed submission error

/// Errors specific to the typed transaction submission API.
public enum TypedSubmissionError: Error, Sendable {
    /// The `Transaction` has no computable ID (e.g. the body was not yet signed).
    case missingTransactionId
}

// MARK: - TxRejection typed decoding

extension TxRejection {

    /// Decode the raw rejection-reason CBOR into any `CBORSerializable` type.
    ///
    /// ```swift
    /// if let reason = try? rejection.decode(SomeRejectionType.self) { ... }
    /// ```
    public func decode<T: CBORSerializable>(_ type: T.Type) throws -> T {
        let data = Data(reasonCBOR.readableBytesView)
        return try T.fromCBOR(data: data)
    }
}

// MARK: - LocalTxSubmissionClient typed submit

extension LocalTxSubmissionClient {

    /// Serialise a fully-typed SwiftCardanoCore `Transaction` to CBOR and submit
    /// it to the node, delegating to the existing `submit(_ tx: RawTransaction)`.
    ///
    /// - Throws: `LocalTxSubmissionError.rejected(_:)` on node rejection,
    ///   or a serialization error if the transaction cannot be CBOR-encoded.
    public func submit(_ tx: Transaction, era: Era = .conway) async throws {
        let data = try tx.toCBORData(deterministic: false)
        var buf = ByteBufferAllocator().buffer(capacity: data.count)
        buf.writeBytes(data)
        let rawTx = RawTransaction(era: era, rawCBOR: buf)
        try await submit(rawTx)
    }

    /// Like `submit(_:era:)` but returns the `TransactionId` on success.
    ///
    /// The transaction ID is derived from `tx.id` before the network call.
    /// If the transaction has no computable ID, `TypedSubmissionError.missingTransactionId`
    /// is thrown without making any network request.
    ///
    /// - Returns: The `TransactionId` of the accepted transaction.
    /// - Throws: `TypedSubmissionError.missingTransactionId` if the transaction
    ///   has no ID, or `LocalTxSubmissionError.rejected(_:)` on node rejection.
    @discardableResult
    public func submitChecked(_ tx: Transaction, era: Era = .conway) async throws -> TransactionId {
        guard let txId = tx.id else {
            throw TypedSubmissionError.missingTransactionId
        }
        try await submit(tx, era: era)
        return txId
    }
}
