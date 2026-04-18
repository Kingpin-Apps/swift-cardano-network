public struct ProtocolConfig: Codable, Sendable {
    /// NtN versions to propose in Handshake, highest-preferred first
    public var ntnVersions: [UInt16] = [14, 13, 12, 11, 10, 9, 8, 7]
    /// NtC versions to propose in Handshake, highest-preferred first.
    /// Wire values include bit 15 (0x8000) per spec §3.1.
    public var ntcVersions: [UInt16] = [32784, 32783, 32782, 32777]   // v16, v15, v14, v9
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
