/// Which party may send the next message in an Ouroboros mini-protocol.
public enum Agency: Sendable {
    /// The client (initiator) sends next.
    case client
    /// The server (responder) sends next.
    case server
    /// Terminal state — no further messages are expected.
    case nobody
}

/// Every mini-protocol state must declare who holds agency.
public protocol ProtocolState: Sendable {
    var agency: Agency { get }
}

/// Errors raised by the protocol driver when the agency rules are violated or
/// when the connection terminates unexpectedly.
public enum ProtocolError: Error, Sendable {
    /// Local code attempted to send a message while the remote side held agency.
    case agencyViolation(protocol: String, state: String, agency: Agency)
    /// Local code attempted to receive a message while the local side held agency.
    case unexpectedReceive(protocol: String, state: String)
    /// The inbound stream ended before the protocol reached a terminal state.
    case connectionClosed
    /// The remote sent a message that is not valid in the current state.
    case invalidTransition(protocol: String, state: String, message: String)
}
