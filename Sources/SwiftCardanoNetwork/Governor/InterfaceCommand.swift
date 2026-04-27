/// A command emitted by the `OutboundGovernor` (and its sub-behaviors) for
/// the underlying `Interface` to execute. Mirrors `pallas-network2`'s
/// `InterfaceCommand`.
///
/// The Interface is responsible for actually performing TCP I/O — the governor
/// only describes what it wants done. This separation makes governor logic
/// testable without sockets and keeps I/O policies (NIO, mock, embedded)
/// pluggable.
public enum InterfaceCommand: Sendable {
    /// Open a connection to `peerID` if one is not already open.
    case connect(PeerID)
    /// Send `message` to `peerID` on its mini-protocol channel.
    /// The Interface encodes via the appropriate codec.
    case send(PeerID, AnyMiniProtocolMessage)
    /// Close the connection to `peerID`. Idempotent.
    case disconnect(PeerID)
}
