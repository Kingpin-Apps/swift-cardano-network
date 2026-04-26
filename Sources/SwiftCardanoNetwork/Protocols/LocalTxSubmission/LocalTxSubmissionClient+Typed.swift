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

    /// Decode the raw rejection-reason CBOR into a generic `Primitive` value.
    ///
    /// Useful when you don't have a typed Swift representation of the
    /// era-specific error (e.g. `ConwayApplyTxErr`). The returned `Primitive`
    /// preserves the full CBOR structure and can be inspected by walking the
    /// list/dict/string cases.
    public func decodedPrimitive() throws -> Primitive {
        let data = Data(reasonCBOR.readableBytesView)
        return try Primitive.fromCBOR(data: data)
    }

    /// A best-effort human-readable rendering of the rejection reason.
    ///
    /// Walks the decoded CBOR `Primitive` structure and emits a JSON-like
    /// string. Cardano nodes typically embed an explanatory text inside the
    /// rejection (e.g. *"All inputs are spent. Transaction has probably already
    /// been included"*); that text appears verbatim in the output. If the CBOR
    /// can't be decoded, returns a hex dump of the raw bytes.
    public var humanReadable: String {
        guard let primitive = try? decodedPrimitive() else {
            let hex = Data(reasonCBOR.readableBytesView)
                .map { String(format: "%02x", $0) }.joined()
            return "<undecodable \(reasonCBOR.readableBytes) bytes: \(hex)>"
        }
        return TxRejection.render(primitive)
    }

    private static func render(_ p: Primitive) -> String {
        switch p {
        case .string(let s):
            return "\"\(s)\""
        case .int(let v):
            return String(v)
        case .uint(let v):
            return String(v)
        case .bool(let v):
            return String(v)
        case .null:
            return "null"
        case .bytes(let d):
            let hex = d.map { String(format: "%02x", $0) }.joined()
            return "h'\(hex)'"
        case .byteArray(let arr):
            let hex = arr.map { String(format: "%02x", $0) }.joined()
            return "h'\(hex)'"
        case .list(let items),
             .frozenList(let items):
            return "[" + items.map { render($0) }.joined(separator: ", ") + "]"
        case .orderedDict(let dict),
             .indefiniteDictionary(let dict):
            let pairs = dict.map { "\(render($0.key)): \(render($0.value))" }
            return "{" + pairs.joined(separator: ", ") + "}"
        case .dict(let dict),
             .frozenDict(let dict):
            let pairs = dict.map { "\(render($0.key)): \(render($0.value))" }
            return "{" + pairs.joined(separator: ", ") + "}"
        case .indefiniteList(let il):
            let items = il.map { render($0) }
            return "[" + items.joined(separator: ", ") + "]"
        case .orderedSet(let s):
            return "set[" + s.elements.map { render($0) }.joined(separator: ", ") + "]"
        case .nonEmptyOrderedSet(let s):
            return "set[" + s.elements.map { render($0) }.joined(separator: ", ") + "]"
        case .cborTag(let tag):
            return "tag(\(tag.tag), \(render(tag.value)))"
        default:
            return "\(p)"
        }
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
