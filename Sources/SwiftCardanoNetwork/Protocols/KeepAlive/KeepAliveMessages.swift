import NIOCore

// MARK: - Protocol messages

/// The complete KeepAlive mini-protocol message set (NtN only, protocol ID 8).
///
/// ## Wire tags
/// ```
/// [0, cookie] — keepAlive(cookie)
/// [1, cookie] — keepAliveResponse(cookie)
/// [2]         — done
/// ```
///
/// The `cookie` is a `UInt16` chosen by the client and echoed verbatim by the
/// server. Mismatched cookies indicate a protocol error.
public enum KeepAliveMessage: Sendable {
    /// Client sends a probe with the given cookie value.
    case keepAlive(cookie: UInt16)
    /// Server echoes back the same cookie.
    case keepAliveResponse(cookie: UInt16)
    /// Client terminates the protocol.
    case done
}

// MARK: - Errors

/// Errors raised by `KeepAliveHandler` and `KeepAliveCodec`.
public enum KeepAliveError: Error, Sendable {
    /// No `keepAliveResponse` arrived before the configured timeout.
    case timeout(cookie: UInt16, elapsedNanoseconds: Int64)
    /// The server echoed a different cookie than the one that was sent.
    case cookieMismatch(sent: UInt16, received: UInt16)
    /// The CBOR message tag was not 0, 1, or 2.
    case unknownMessageTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
}
