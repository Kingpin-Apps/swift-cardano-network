/// States of the Request-Response mini-protocol state machine
/// (dummy protocol, §3.5.2).
///
/// ```
/// [Idle] ──request──► [Busy] ──response──► [Idle]
///   │
///   └──done──► [Done]
/// ```
public enum ReqRespState: ProtocolState, Sendable, Equatable, CustomStringConvertible {

    /// Waiting for the client to send the next request. Client holds agency.
    case idle
    /// Request sent; waiting for the server to reply. Server holds agency.
    case busy
    /// Terminal state. No further messages are expected.
    case done

    public var agency: Agency {
        switch self {
        case .idle: return .client
        case .busy: return .server
        case .done: return .nobody
        }
    }

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .busy: return "busy"
        case .done: return "done"
        }
    }
}

// MARK: - Transitions

extension ReqRespState {

    func afterSend<Request: Sendable, Response: Sendable>(
        _ message: ReqRespMessage<Request, Response>
    ) throws -> ReqRespState {
        switch (self, message) {
        case (.idle, .request): return .busy
        case (.idle, .done):    return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "reqResp",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive<Request: Sendable, Response: Sendable>(
        _ message: ReqRespMessage<Request, Response>
    ) throws -> ReqRespState {
        switch (self, message) {
        case (.busy, .response): return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "reqResp",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
