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
    /// Peer-sharing willingness advertised in the NtN handshake (§3.11).
    ///
    /// - `0` = `PeerSharingDisabled` — refuse inbound share requests; the
    ///   peer-sharing mini-protocol server is not run.
    /// - `1` = `PeerSharingEnabled` — accept and respond to share requests.
    ///
    /// The flag is only included in proposed version data for NtN ≥ 11.
    /// A client can still issue outbound `MsgShareRequest` calls regardless
    /// of its own advertised value, but the **remote** peer must advertise
    /// `1` for it to run a peer-sharing server.
    public var peerSharing: UInt8 = 0

    public init() {}

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case ntnVersions
        case ntcVersions
        case ntnMaxSDUSize
        case ntcMaxSDUSize
        case keepAliveIntervalSeconds
        case keepAliveTimeoutSeconds
        case peerSharing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var value = ProtocolConfig()
        if let v = try c.decodeIfPresent([UInt16].self, forKey: .ntnVersions) { value.ntnVersions = v }
        if let v = try c.decodeIfPresent([UInt16].self, forKey: .ntcVersions) { value.ntcVersions = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .ntnMaxSDUSize) { value.ntnMaxSDUSize = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .ntcMaxSDUSize) { value.ntcMaxSDUSize = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .keepAliveIntervalSeconds) {
            value.keepAliveIntervalSeconds = v
        }
        if let v = try c.decodeIfPresent(Double.self, forKey: .keepAliveTimeoutSeconds) {
            value.keepAliveTimeoutSeconds = v
        }
        if let v = try c.decodeIfPresent(UInt8.self, forKey: .peerSharing) { value.peerSharing = v }
        self = value
    }
}
