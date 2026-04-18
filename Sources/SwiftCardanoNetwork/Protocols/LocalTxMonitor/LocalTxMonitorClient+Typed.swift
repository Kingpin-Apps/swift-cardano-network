import Foundation
import NIOCore
import SwiftCardanoCore

// MARK: - MempoolTx typed decoding

extension MempoolTx {

    /// Decode this mempool entry into a fully-typed SwiftCardanoCore `Transaction`.
    ///
    /// `rawCBOR` contains the CBOR-encoded transaction body as received from the
    /// node via `LocalTxMonitor`.  SwiftCardanoCore's `Transaction.fromCBOR(data:)`
    /// expects a 4-element array `[body, witnessSet, valid, auxiliaryData]`.
    ///
    /// - Throws: `CardanoCoreError.deserializeError` if the bytes are malformed.
    public func decode() throws -> Transaction {
        let data = Data(rawCBOR.readableBytesView)
        return try Transaction.fromCBOR(data: data)
    }
}

// MARK: - LocalTxMonitorClient typed snapshot

extension LocalTxMonitorClient {

    /// Acquire a mempool snapshot and decode each entry as a SwiftCardanoCore
    /// `Transaction`, returning the slot number alongside the decoded transactions.
    ///
    /// This wraps `snapshot()` and decodes each `MempoolTx.rawCBOR`.  Decode
    /// errors are propagated immediately; partial results are not returned.
    ///
    /// - Returns: `(slotNo:txs:)` — the slot at which the snapshot was taken
    ///   and an array of decoded transactions.
    public func snapshotTyped() async throws -> (slotNo: UInt64, txs: [Transaction]) {
        let (slotNo, rawTxs) = try await snapshot()
        let txs = try rawTxs.map { try $0.decode() }
        return (slotNo: slotNo, txs: txs)
    }
}
