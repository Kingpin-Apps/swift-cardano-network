/// States of the LocalStateQuery mini-protocol state machine (NtC, protocol ID 7).
///
/// ```
///            Acquire / AcquireVolatileTip
/// [Idle] ───────────────────────────────► [Acquiring] ──Acquired──► [Acquired]
///   │                                          │                    │        │
///   └──Done──► [Done]               Failure────┘               Query│     Release
///                                         ▼                         │        │
///                                      [Idle]                  [Querying] [Idle]
///                                                                   │
///                                                                 Result
///                                                                   │
///                                                              [Acquired]
///
/// ReAcquire (from Acquired) sends back to Acquiring.
/// ```
public enum LocalStateQueryState: ProtocolState, Sendable, Equatable, CustomStringConvertible {

    /// Waiting for the client to act. Client holds agency.
    case idle
    /// Acquire sent; waiting for the node to confirm. Server holds agency.
    case acquiring
    /// A chain snapshot has been acquired; client may query, release, or re-acquire.
    /// Client holds agency.
    case acquired
    /// A query has been sent; waiting for the result. Server holds agency.
    case querying
    /// Terminal state. No further messages are expected.
    case done

    public var agency: Agency {
        switch self {
        case .idle:      return .client
        case .acquiring: return .server
        case .acquired:  return .client
        case .querying:  return .server
        case .done:      return .nobody
        }
    }

    public var description: String {
        switch self {
        case .idle:      return "idle"
        case .acquiring: return "acquiring"
        case .acquired:  return "acquired"
        case .querying:  return "querying"
        case .done:      return "done"
        }
    }
}

// MARK: - Transitions

extension LocalStateQueryState {

    func afterSend(_ message: LocalStateQueryMessage) throws -> LocalStateQueryState {
        switch (self, message) {
        case (.idle, .acquire):            return .acquiring
        case (.idle, .acquireVolatileTip): return .acquiring
        case (.idle, .done):               return .done
        case (.acquired, .query):          return .querying
        case (.acquired, .release):        return .idle
        case (.acquired, .reAcquire):      return .acquiring
        default:
            throw ProtocolError.invalidTransition(
                protocol: "localStateQuery",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: LocalStateQueryMessage) throws -> LocalStateQueryState {
        switch (self, message) {
        case (.acquiring, .acquired): return .acquired
        case (.acquiring, .failure):  return .idle
        case (.querying, .result):    return .acquired
        default:
            throw ProtocolError.invalidTransition(
                protocol: "localStateQuery",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
