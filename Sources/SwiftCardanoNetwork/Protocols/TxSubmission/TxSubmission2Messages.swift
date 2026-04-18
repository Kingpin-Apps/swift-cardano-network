import NIOCore

// MARK: - Primitive types

/// A 32-byte Cardano transaction identifier.
public typealias TxId = [UInt8]

/// A transaction identifier paired with the byte size of the transaction body.
/// Sent in `replyTxIds` so the remote peer can budget its download requests.
public struct TxIdWithSize: Sendable {
    public let id: TxId
    public let size: UInt32

    public init(id: TxId, size: UInt32) {
        self.id = id
        self.size = size
    }
}

// MARK: - Protocol messages

/// The complete TxSubmission2 mini-protocol message set (NtN only, protocol ID 4).
///
/// TxSubmission2 is **pull-based**: the remote node drives the exchange by asking
/// the local peer for transaction IDs and bodies. The local peer maintains a
/// mempool and responds to these requests.
///
/// ## Wire tags
/// ```
/// msgRequestTxIds = [0, bool, uint16, uint16]   ; blocking, ackCount, reqCount
/// msgReplyTxIds   = [1, [[bstr, uint]]]          ; [(txId, byteSize)]
/// msgRequestTxs   = [2, [bstr]]                  ; [txId]
/// msgReplyTxs     = [3, [bstr]]                  ; [rawTx CBOR]
/// msgDone         = [4]
/// ```
public enum TxSubmission2Message: Sendable {
    // Server → Client (node requests)
    /// Ask for up to `reqCount` new transaction IDs, acknowledging `ackCount`
    /// previously advertised IDs. If `blocking` is true the client may wait
    /// until at least one new transaction is available before replying.
    case requestTxIds(blocking: Bool, ackCount: UInt16, reqCount: UInt16)
    /// Ask for the full bodies of the listed transaction IDs.
    case requestTxs([TxId])
    /// Terminate the protocol.
    case done

    // Client → Server (local peer replies)
    /// Advertise transaction IDs with their sizes.
    case replyTxIds([TxIdWithSize])
    /// Provide the requested transaction bodies as raw CBOR byte buffers.
    case replyTxs([ByteBuffer])
}

// MARK: - Errors

public enum TxSubmission2Error: Error, Sendable {
    case unknownMessageTag(UInt64)
    case unexpectedArrayLength(Int)
    case malformedTxIdEntry(arrayLength: Int)
}
