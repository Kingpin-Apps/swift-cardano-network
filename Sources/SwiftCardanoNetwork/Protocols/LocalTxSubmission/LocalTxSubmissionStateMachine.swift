/// States of the LocalTxSubmission mini-protocol state machine.
///
/// ```
///                     submitTx
/// [Idle] ─────────────────────────► [Busy] ──acceptTx──► [Idle]
///   │      (client agency)                  ──rejectTx──► [Idle]
///   │
///   └──done──► [Done]
/// ```
public enum LocalTxSubmissionState: ProtocolState, Sendable, Equatable, CustomStringConvertible {
    /// Waiting to submit. Client holds agency.
    case idle
    /// Transaction submitted; waiting for node response. Server holds agency.
    case busy
    /// Terminal state.
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

extension LocalTxSubmissionState {
    func afterSend(_ message: LocalTxSubmissionMessage) throws -> LocalTxSubmissionState {
        switch (self, message) {
        case (.idle, .submitTx): return .busy
        case (.idle, .done):     return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "localTxSubmission",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: LocalTxSubmissionMessage) throws -> LocalTxSubmissionState {
        switch (self, message) {
        case (.busy, .acceptTx): return .idle
        case (.busy, .rejectTx): return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "localTxSubmission",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
