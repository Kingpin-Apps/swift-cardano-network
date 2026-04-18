/// States of the LocalTxMonitor mini-protocol state machine (NtC, protocol ID 9).
///
/// ```
///                 Acquire
/// [Idle] ──────────────────► [Acquiring] ──Acquired──► [Acquired]
///   │                                                   │  │  │
///   └──Done──► [Done]                             NextTx│  │  │Release
///                                                       │  │  │
///                                              HasTx────┘  │  └──► [Idle]
///                                              GetCap───── ┘
///                                                       │
///                                                  [Busy] ──ReplyX──► [Acquired]
/// ```
public enum LocalTxMonitorState: ProtocolState, Sendable, Equatable, CustomStringConvertible {

    /// Waiting for the client to act. Client holds agency.
    case idle
    /// Acquire sent; waiting for the node to confirm. Server holds agency.
    case acquiring
    /// A mempool snapshot has been acquired; client may query or release. Client holds agency.
    case acquired
    /// A query has been sent; waiting for the reply. Server holds agency.
    case busy
    /// Terminal state. No further messages are expected.
    case done

    public var agency: Agency {
        switch self {
        case .idle:      return .client
        case .acquiring: return .server
        case .acquired:  return .client
        case .busy:      return .server
        case .done:      return .nobody
        }
    }

    public var description: String {
        switch self {
        case .idle:      return "idle"
        case .acquiring: return "acquiring"
        case .acquired:  return "acquired"
        case .busy:      return "busy"
        case .done:      return "done"
        }
    }
}

// MARK: - Transitions

extension LocalTxMonitorState {

    func afterSend(_ message: LocalTxMonitorMessage) throws -> LocalTxMonitorState {
        switch (self, message) {
        case (.idle, .acquire):         return .acquiring
        case (.idle, .done):            return .done
        case (.acquired, .awaitAcquire): return .acquiring
        case (.acquired, .nextTx):      return .busy
        case (.acquired, .hasTx):       return .busy
        case (.acquired, .getSizes):    return .busy
        case (.acquired, .getMeasures): return .busy
        case (.acquired, .release):     return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "localTxMonitor",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: LocalTxMonitorMessage) throws -> LocalTxMonitorState {
        switch (self, message) {
        case (.acquiring, .acquired):        return .acquired
        case (.busy, .replyNextTx):          return .acquired
        case (.busy, .replyHasTx):           return .acquired
        case (.busy, .replyGetSizes):        return .acquired
        case (.busy, .replyGetMeasures):     return .acquired
        default:
            throw ProtocolError.invalidTransition(
                protocol: "localTxMonitor",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
