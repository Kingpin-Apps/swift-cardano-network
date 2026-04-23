import NIOCore

// MARK: - Protocol messages

/// The complete Request-Response mini-protocol message set
/// (dummy protocol, §3.5.2).
///
/// The Request-Response protocol is polymorphic in the request and response
/// payload types. The client sends a request, the server replies with a
/// single response, and either side terminates via `done`.
///
/// ## Wire tags
/// ```
/// [0]             — done
/// [1, request]    — request(request)
/// [2, response]   — response(response)
/// ```
///
/// > Note: Dummy protocols are not used by `cardano-node` and are not part of
/// > either the Node-to-Node or Node-to-Client protocol suites. They exist
/// > for tests, demos, and framework familiarisation.
public enum ReqRespMessage<Request: Sendable, Response: Sendable>: Sendable {
    /// The client sends a request to the server.
    case request(Request)
    /// The server replies with a response.
    case response(Response)
    /// Terminate the protocol.
    case done
}

// MARK: - Errors

/// Errors raised by `ReqRespCodec`.
public enum ReqRespError: Error, Sendable, Equatable {
    /// The CBOR message tag was not 0, 1, or 2.
    case unknownMessageTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
}
