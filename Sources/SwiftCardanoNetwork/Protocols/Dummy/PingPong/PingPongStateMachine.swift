/// States of the Ping-Pong mini-protocol state machine (dummy protocol, §3.5.1).
///
/// ```
/// [Idle] ──ping──► [Busy] ──pong──► [Idle]
///   │
///   └──done──► [Done]
/// ```
public enum PingPongState: ProtocolState, Sendable, Equatable, CustomStringConvertible {

    /// Waiting for the client to send the next ping. Client holds agency.
    case idle
    /// Ping sent; waiting for the server to reply with pong. Server holds agency.
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

extension PingPongState {

    func afterSend(_ message: PingPongMessage) throws -> PingPongState {
        switch (self, message) {
        case (.idle, .ping): return .busy
        case (.idle, .done): return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "pingPong",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: PingPongMessage) throws -> PingPongState {
        switch (self, message) {
        case (.busy, .pong): return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "pingPong",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
