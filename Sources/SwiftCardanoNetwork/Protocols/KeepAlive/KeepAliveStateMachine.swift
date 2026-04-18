/// States of the KeepAlive mini-protocol state machine (NtN, protocol ID 8).
///
/// ```
/// [Idle] ──keepAlive(cookie)──► [Busy] ──keepAliveResponse(cookie)──► [Idle]
///   │
///   └──done──► [Done]
/// ```
public enum KeepAliveState: ProtocolState, Sendable, Equatable, CustomStringConvertible {

    /// Waiting for the client to send the next probe. Client holds agency.
    case idle
    /// Probe sent; waiting for the server to echo the cookie. Server holds agency.
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

extension KeepAliveState {

    func afterSend(_ message: KeepAliveMessage) throws -> KeepAliveState {
        switch (self, message) {
        case (.idle, .keepAlive):  return .busy
        case (.idle, .done):       return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "keepAlive",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: KeepAliveMessage) throws -> KeepAliveState {
        switch (self, message) {
        case (.busy, .keepAliveResponse): return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "keepAlive",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
