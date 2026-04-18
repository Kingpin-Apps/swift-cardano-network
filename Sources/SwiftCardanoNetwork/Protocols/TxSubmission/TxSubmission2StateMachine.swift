/// States of the TxSubmission2 mini-protocol state machine (NtN only).
///
/// Unlike most Ouroboros protocols, TxSubmission2 starts with **server agency**:
/// the remote node drives the exchange by requesting transaction IDs and bodies.
///
/// ```
///                    requestTxIds(blocking:true)  ──► [TxIdsBlocking]
///                   /                                        │
/// [Idle] ──────────   requestTxIds(blocking:false) ──► [TxIdsNonBlocking]  ──replyTxIds──► [Idle]
///   (server)          \                                                                        │
///                      requestTxs ──► [Txs] ──replyTxs──────────────────────────────────────►│
///                      done      ──► [Done]
/// ```
public enum TxSubmission2State: ProtocolState, Sendable, Equatable {
    /// Waiting for the node to request IDs, bodies, or signal done. Server has agency.
    case idle
    /// Blocking `requestTxIds` received; client must reply (may wait for new txs). Client has agency.
    case txIdsBlocking
    /// Non-blocking `requestTxIds` received; client must reply immediately. Client has agency.
    case txIdsNonBlocking
    /// `requestTxs` received; client must supply bodies. Client has agency.
    case txs
    /// Terminal state.
    case done

    public var agency: Agency {
        switch self {
        case .idle:                                       return .server
        case .txIdsBlocking, .txIdsNonBlocking, .txs:   return .client
        case .done:                                       return .nobody
        }
    }
}

// MARK: - Transitions

extension TxSubmission2State {
    /// Transitions driven by messages **received from** the server.
    func afterReceive(_ message: TxSubmission2Message) throws -> TxSubmission2State {
        switch (self, message) {
        case (.idle, .requestTxIds(let blocking, _, _)):
            return blocking ? .txIdsBlocking : .txIdsNonBlocking
        case (.idle, .requestTxs):
            return .txs
        case (.idle, .done):
            return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "txSubmission2",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    /// Transitions driven by messages **sent to** the server.
    func afterSend(_ message: TxSubmission2Message) throws -> TxSubmission2State {
        switch (self, message) {
        case (.txIdsBlocking, .replyTxIds),
             (.txIdsNonBlocking, .replyTxIds):
            return .idle
        case (.txs, .replyTxs):
            return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "txSubmission2",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
