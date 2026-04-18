import NIOCore

/// A single Ouroboros Segment Data Unit (SDU).
///
/// Wire layout (big-endian, 8-byte header):
/// ```
///  0               1               2               3
///  0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
/// ├───────────────────────────────────────────────────────────────────┤
/// │                  Transmission Timestamp (32 bits)                 │
/// ├───────────────────────────────────────────────────────────────────┤
/// │M│         Mini-Protocol ID (15 bits)            │  Length (16 b) │
/// ├───────────────────────────────────────────────────────────────────┤
/// │                     Payload (0–65535 bytes)                       │
/// └───────────────────────────────────────────────────────────────────┘
/// ```
public struct MuxSDU: @unchecked Sendable {
    /// Lower 32 bits of the monotonic clock in microseconds.
    public let timestamp: UInt32
    /// Raw 16-bit field: top bit = mode, lower 15 bits = protocol number.
    public let protocolID: UInt16
    /// Number of bytes in `payload`.
    public let payloadLength: UInt16
    /// The protocol-specific CBOR payload.
    public var payload: ByteBuffer

    public init(timestamp: UInt32, protocolID: UInt16, payload: ByteBuffer) {
        self.timestamp = timestamp
        self.protocolID = protocolID
        self.payloadLength = UInt16(payload.readableBytes)
        self.payload = payload
    }

    /// `true` when the mode bit is set (responder/server side).
    public var isResponder: Bool { (protocolID & 0x8000) != 0 }

    /// The 15-bit mini-protocol number (without the mode bit).
    public var miniProtocolID: UInt16 { protocolID & 0x7FFF }
}

// MARK: - Known protocol identifiers

public extension MuxSDU {
    enum ProtocolID {
        public static let handshake:          UInt16 = 0
        public static let chainSync:          UInt16 = 2   // NtN
        public static let blockFetch:         UInt16 = 3
        public static let txSubmission2:      UInt16 = 4
        public static let ntcChainSync:       UInt16 = 5   // NtC
        public static let localTxSubmission:  UInt16 = 6
        public static let localStateQuery:    UInt16 = 7
        public static let keepAlive:          UInt16 = 8
        public static let localTxMonitor:     UInt16 = 9
        public static let peerSharing:        UInt16 = 10
    }
}
