/// States of the ChainSync mini-protocol state machine.
///
/// ```
///                      requestNext
///   ┌────────────────────────────────────────────────────────────────┐
///   │                                                                │
///   ▼                                                                │
/// [Idle]──requestNext──►[CanAwait]──awaitReply──►[MustReply]        │
///   │                       │                        │              │
///   │                 rollForward/Backward      rollForward/Backward │
///   │                       │                        │              │
///   │                       └──────────────►[Idle]◄──┘              │
///   │                                        │                      │
///   │                                        └──────────────────────┘
///   │
///   └──findIntersect──►[Intersect]──intersectFound/NotFound──►[Idle]
///   │
///   └──done──►[Done]
/// ```
public enum ChainSyncState: ProtocolState, Sendable {
    /// Initial / post-response state. Client sends next.
    case idle
    /// `RequestNext` sent; server may respond immediately or with `AwaitReply`.
    case canAwait
    /// `AwaitReply` received; server *must* eventually reply with `RollForward` or `RollBackward`.
    case mustReply
    /// `FindIntersect` sent; waiting for `IntersectFound` or `IntersectNotFound`.
    case intersect
    /// Terminal state.
    case done

    public var agency: Agency {
        switch self {
        case .idle:                   return .client
        case .canAwait, .mustReply, .intersect: return .server
        case .done:                   return .nobody
        }
    }
}

// MARK: - Transitions

extension ChainSyncState {
    func afterSend(_ message: ChainSyncMessage) throws -> ChainSyncState {
        switch (self, message) {
        case (.idle, .requestNext):     return .canAwait
        case (.idle, .findIntersect):   return .intersect
        case (.idle, .done):            return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "chainSync",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: ChainSyncMessage) throws -> ChainSyncState {
        switch (self, message) {
        case (.canAwait, .awaitReply):                  return .mustReply
        case (.canAwait, .rollForward),
             (.canAwait, .rollBackward),
             (.mustReply, .rollForward),
             (.mustReply, .rollBackward):               return .idle
        case (.intersect, .intersectFound),
             (.intersect, .intersectNotFound):          return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "chainSync",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
