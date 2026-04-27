/// A network-level peer identity (host + port).
///
/// `PeerID` is the key used by the `OutboundGovernor` to track a peer across
/// every mini-protocol state machine. It deliberately models the wire-level
/// identity only — DNS resolution, peer classes (root/ledger/shared), and
/// reputation live in higher layers.
///
/// Construct directly, parse from a "host:port" string, or convert from a
/// `PeerAddress` returned by the Peer-Sharing mini-protocol (§3.11).
public struct PeerID: Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { "\(host):\(port)" }
}

// MARK: - PeerAddress conversion

extension PeerID {
    /// Build a `PeerID` from a Peer-Sharing protocol address (§3.11.7).
    public init(_ address: PeerAddress) {
        self.host = address.host
        self.port = address.port
    }
}

// MARK: - String parsing

extension PeerID {
    /// Parse `"host:port"` (IPv4 or hostname) into a `PeerID`.
    /// Returns `nil` on malformed input.
    public init?(parsing s: String) {
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        let portStr = String(s[s.index(after: colon)...])
        guard let port = UInt16(portStr), !host.isEmpty else { return nil }
        self.host = host
        self.port = port
    }
}
