public struct ProtocolConfig: Codable, Sendable {
    /// NtN versions to propose in Handshake, highest-preferred first
    public var ntnVersions: [UInt16] = [14, 13, 12, 11, 10, 9, 8, 7]
    /// NtC versions to propose in Handshake, highest-preferred first.
    /// Wire values include bit 15 (0x8000) per spec §3.1.
    ///
    /// Defaults to every NtC version this library knows how to encode against,
    /// from v23 down to the legacy v9.  The handshake decoder picks the
    /// highest mutually supported version; query factories in
    /// `LedgerQuery+Typed.swift` switch wire form per the negotiated version
    /// (see `NtcQueryGate`), so the same default works on cardano-node 10.6.x
    /// (v22), 10.7.0+ (v23), and any older binary that still advertises
    /// v9..v21.
    public var ntcVersions: [UInt16] = NodeToClientVersion.allKnown
    /// Max SDU payload size for NtN connections in bytes
    public var ntnMaxSDUSize: Int = 12_288
    /// Max SDU payload size for NtC connections in bytes
    public var ntcMaxSDUSize: Int = 12_288
    /// Seconds between KeepAlive probes on NtN connections
    public var keepAliveIntervalSeconds: Double = 60.0
    /// Seconds to wait for a KeepAlive response before declaring the connection dead
    public var keepAliveTimeoutSeconds: Double = 10.0

    public init() {}
}
