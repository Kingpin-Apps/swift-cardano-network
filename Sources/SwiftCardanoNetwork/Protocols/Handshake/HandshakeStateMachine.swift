/// States of the Handshake mini-protocol state machine.
///
/// ```
///   [Start] ──ProposeVersions──► [Proposed]
///                                     │
///                     ┌───────────────┴───────────────┐
///                     │                               │
///               AcceptVersion                       Refuse
///                     │                               │
///                  [Done ✓]                       [Done ✗]
/// ```
public enum HandshakeState: ProtocolState, Sendable {
    /// Initial state. Client holds agency and must send `ProposeVersions`.
    case start
    /// `ProposeVersions` has been sent. Server holds agency.
    case proposed
    /// Terminal: server accepted a version.
    case accepted
    /// Terminal: server refused the handshake.
    case refused

    public var agency: Agency {
        switch self {
        case .start:    return .client
        case .proposed: return .server
        case .accepted, .refused: return .nobody
        }
    }
}

// MARK: - Transitions

extension HandshakeState {
    /// Advance the state on a *send* event.
    func afterSend(_ message: HandshakeMessage) throws -> HandshakeState {
        switch (self, message) {
        case (.start, .proposeVersions):
            return .proposed
        default:
            throw ProtocolError.invalidTransition(
                protocol: "handshake",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    /// Advance the state on a *receive* event.
    func afterReceive(_ message: HandshakeMessage) throws -> HandshakeState {
        switch (self, message) {
        case (.proposed, .acceptVersion):
            return .accepted
        case (.proposed, .refuse):
            return .refused
        default:
            throw ProtocolError.invalidTransition(
                protocol: "handshake",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
