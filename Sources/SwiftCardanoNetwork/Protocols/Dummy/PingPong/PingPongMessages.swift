import NIOCore

// MARK: - Protocol messages

/// The complete Ping-Pong mini-protocol message set (dummy protocol, §3.5.1).
///
/// The Ping-Pong protocol is a simple liveness check: the client sends a
/// `ping`, the server replies with a `pong`, and either side terminates via
/// `done`. Messages carry no payload.
///
/// ## Wire tags
/// ```
/// [0] — done
/// [1] — ping
/// [2] — pong
/// ```
///
/// > Note: Dummy protocols are not used by `cardano-node` and are not part of
/// > either the Node-to-Node or Node-to-Client protocol suites. They exist
/// > for tests, demos, and framework familiarisation.
public enum PingPongMessage: Sendable, Equatable {
    /// The client sends a Ping request to the server.
    case ping
    /// The server replies to a Ping with a Pong.
    case pong
    /// The client terminates the protocol.
    case done
}

// MARK: - Errors

/// Errors raised by `PingPongCodec`.
public enum PingPongError: Error, Sendable, Equatable {
    /// The CBOR message tag was not 0, 1, or 2.
    case unknownMessageTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
}
