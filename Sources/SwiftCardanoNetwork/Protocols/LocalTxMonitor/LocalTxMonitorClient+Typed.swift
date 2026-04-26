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

// MARK: - Typed mempool result types

/// A typed mempool snapshot: the slot at which it was taken and its decoded transactions.
public struct MempoolSnapshot: Sendable {
    /// The slot number of the virtual block under construction when the snapshot was taken.
    public let slotNo: UInt64
    /// The transactions in the snapshot, decoded into SwiftCardanoCore `Transaction` values.
    public let txs: [Transaction]

    public init(slotNo: UInt64, txs: [Transaction]) {
        self.slotNo = slotNo
        self.txs = txs
    }
}

/// Extended mempool measure data: total transaction count plus named (current, capacity) pairs.
public struct MempoolMeasures: Sendable {

    /// A single named mempool measure.
    public struct Measure: Sendable, Equatable {
        /// The measure name (e.g. `"Transaction count"`, `"Memory bytes"`).
        public let key: String
        /// The current value of this measure.
        public let current: Int64
        /// The capacity (limit) for this measure.
        public let capacity: Int64

        public init(key: String, current: Int64, capacity: Int64) {
            self.key = key
            self.current = current
            self.capacity = capacity
        }
    }

    /// Total number of transactions in the current mempool snapshot.
    public let totalTxs: UInt32
    /// The named measure pairs reported by the node.
    public let measures: [Measure]

    public init(totalTxs: UInt32, measures: [Measure]) {
        self.totalTxs = totalTxs
        self.measures = measures
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
    /// - Returns: A `MempoolSnapshot` with the slot at which the snapshot was
    ///   taken and the decoded transactions.
    public func snapshotTyped() async throws -> MempoolSnapshot {
        let (slotNo, rawTxs) = try await snapshot()
        let txs = try rawTxs.map { try $0.decode() }
        return MempoolSnapshot(slotNo: slotNo, txs: txs)
    }

    /// Acquire a mempool snapshot and return its extended measure data as a typed
    /// `MempoolMeasures` struct.
    ///
    /// Wraps `measures()` and lifts the raw tuples into `MempoolMeasures.Measure`.
    public func measuresTyped() async throws -> MempoolMeasures {
        let (totalTxs, raw) = try await measures()
        let measures = raw.map {
            MempoolMeasures.Measure(key: $0.key, current: $0.current, capacity: $0.capacity)
        }
        return MempoolMeasures(totalTxs: totalTxs, measures: measures)
    }
}
