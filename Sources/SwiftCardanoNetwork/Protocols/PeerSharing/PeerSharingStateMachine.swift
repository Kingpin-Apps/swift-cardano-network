/// States of the Peer-Sharing mini-protocol state machine (§3.11.2, NtN ID 10).
///
/// ```
/// [Idle] ──shareRequest──► [Busy] ──sharePeers──► [Idle]
///   │
///   └──done──► [Done]
/// ```
public enum PeerSharingState: ProtocolState, Sendable, Equatable, CustomStringConvertible {

    /// Waiting to send the next request. Client holds agency.
    case idle
    /// Request sent; waiting for the server's reply. Server holds agency.
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

extension PeerSharingState {

    func afterSend(_ message: PeerSharingMessage) throws -> PeerSharingState {
        switch (self, message) {
        case (.idle, .shareRequest): return .busy
        case (.idle, .done):         return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "peerSharing",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: PeerSharingMessage) throws -> PeerSharingState {
        switch (self, message) {
        case (.busy, .sharePeers): return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "peerSharing",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
