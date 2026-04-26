import NIOCore

// MARK: - Primitive types

/// A raw, CBOR-encoded Cardano transaction as returned by the mempool snapshot.
///
/// Decode `rawCBOR` with `swift-cardano-core` to obtain a typed transaction.
public struct MempoolTx: @unchecked Sendable {
    public var rawCBOR: ByteBuffer

    public init(rawCBOR: ByteBuffer) {
        self.rawCBOR = rawCBOR
    }
}

/// The current mempool size metrics returned by `getSizes`.
public struct MempoolCapacity: Sendable, Equatable {
    /// Maximum number of bytes the mempool can hold.
    public let capacityInBytes: UInt64
    /// Number of bytes currently occupied by pending transactions.
    public let sizeInBytes: UInt64
    /// Number of transactions currently in the mempool.
    public let numberOfTxs: UInt64

    public init(capacityInBytes: UInt64, sizeInBytes: UInt64, numberOfTxs: UInt64) {
        self.capacityInBytes = capacityInBytes
        self.sizeInBytes = sizeInBytes
        self.numberOfTxs = numberOfTxs
    }
}

// MARK: - Era indices

/// CardanoBlock era indices, used to wrap transaction IDs in `OneEraGenTxId`
/// form when speaking the HardFork-aware Node-to-Client protocol.
///
/// Cardano nodes that speak the HardFork combinator (NtC v9+) decode the
/// `MsgHasTx` payload as `OneEraGenTxId`, which is encoded on the wire as
/// `[eraIndex, txIdBytes]`.  Sending a bare 32-byte hash without the era
/// wrapper causes the node to reject the message and close the connection.
public enum CardanoEraIndex {
    public static let byron:   UInt64 = 0
    public static let shelley: UInt64 = 1
    public static let allegra: UInt64 = 2
    public static let mary:    UInt64 = 3
    public static let alonzo:  UInt64 = 4
    public static let babbage: UInt64 = 5
    public static let conway:  UInt64 = 6

    /// Eras tried by `LocalTxMonitorClient.hasTx`, ordered newest-first.
    /// Byron is intentionally omitted: its txid format differs from the
    /// 32-byte Blake2b-256 hash used in every other era and Byron-era
    /// transactions are not relevant to current mempool lookups.
    public static let hasTxRetryOrder: [UInt64] = [
        conway, babbage, alonzo, mary, allegra, shelley,
    ]
}

// MARK: - Protocol messages

/// The complete LocalTxMonitor mini-protocol message set (NtC only, protocol ID 9).
///
/// ## Wire tags (spec §3.14.5)
/// ```
/// [0]                                          — done
/// [1]                                          — acquire / awaitAcquire (same encoding)
/// [2, slotNo]                                  — acquired(slotNo)
/// [3]                                          — release
/// [5]                                          — nextTx  (tag 4 unused)
/// [6]           / [6, bstr]                    — replyNextTx(tx?)
/// [7, [eraIndex, bstr]]                        — hasTx(eraIndex, txId)  ; OneEraGenTxId
/// [8, bool]                                    — replyHasTx(bool)
/// [9]                                          — getSizes
/// [10, [uint, uint, uint]]                     — replyGetSizes(capacity, size, count)
/// [11]                                         — getMeasures
/// [12, uint, {* text => [integer, integer]}]   — replyGetMeasures(totalTxs, measures)
/// ```
public enum LocalTxMonitorMessage: Sendable {

    // MARK: Client → Server

    /// Acquire a consistent snapshot of the current mempool.
    case acquire
    /// Await a new snapshot different from the one currently acquired (re-acquire).
    /// Encodes identically to `acquire` on the wire; the state machine distinguishes them.
    case awaitAcquire
    /// Release the current snapshot and return to `Idle`.
    case release
    /// Request the next transaction in the current snapshot (nil reply = end of snapshot).
    case nextTx
    /// Ask whether a specific transaction is present in the current snapshot.
    ///
    /// `eraIndex` selects the era under which the txid bytes should be interpreted
    /// (see `CardanoEraIndex`).  The cardano-node decoder uses this to dispatch
    /// to the era-specific GenTxId parser.  For 32-byte Blake2b-256 hashes
    /// (Shelley-era and later) any post-Byron index works to identify the
    /// transaction by hash; `LocalTxMonitorClient.hasTx` retries across eras
    /// to handle nodes that don't normalise across eras (see Ogmios 6.2.0
    /// release notes and IntersectMBO/ouroboros-consensus#1009).
    case hasTx(eraIndex: UInt64, txId: TxId)
    /// Request the current mempool size metrics (capacity, used bytes, tx count).
    case getSizes
    /// Request extended mempool measure data.
    case getMeasures
    /// Terminate the protocol.
    case done

    // MARK: Server → Client

    /// Snapshot acquired; `slotNo` is the slot of the virtual block under construction.
    case acquired(slotNo: UInt64)
    /// The next transaction in the snapshot. `nil` means the snapshot is exhausted.
    case replyNextTx(MempoolTx?)
    /// Whether the queried transaction is present in the current snapshot.
    case replyHasTx(Bool)
    /// Current mempool size metrics.
    case replyGetSizes(MempoolCapacity)
    /// Extended mempool measures: total tx count and a map of named measure pairs.
    case replyGetMeasures(totalTxs: UInt32, measures: [(key: String, current: Int64, capacity: Int64)])
}

// MARK: - Errors

/// Errors raised by `LocalTxMonitorClient` and `LocalTxMonitorCodec`.
public enum LocalTxMonitorError: Error, Sendable {
    /// The CBOR message tag was not a recognised LocalTxMonitor code.
    case unknownMessageTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
    /// `measures()` was invoked but the negotiated NtC version is too old to
    /// support `MsgGetMeasures` (requires v19+).  Override
    /// `ProtocolConfig.ntcVersions` to enable.
    case measuresNotSupported(negotiatedVersion: UInt16, requiredVersion: UInt16)
}
