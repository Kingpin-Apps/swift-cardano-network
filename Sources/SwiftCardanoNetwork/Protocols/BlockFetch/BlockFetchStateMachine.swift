/// States of the BlockFetch mini-protocol state machine (NtN only).
///
/// ```
/// [Idle]──requestRange──►[Busy]──startBatch──►[Streaming]──block──►[Streaming]
///   │                      │                       │
///   │                   noBlocks               batchDone
///   │                      │                       │
///   └──clientDone──►[Done] └───────────────►[Idle]◄┘
/// ```
public enum BlockFetchState: ProtocolState, Sendable {
    /// Waiting for the client to issue a request or signal it is done.
    case idle
    /// Range requested; waiting for the server to respond with `startBatch` or `noBlocks`.
    case busy
    /// Batch started; server is streaming block bodies.
    case streaming
    /// Terminal state.
    case done

    public var agency: Agency {
        switch self {
        case .idle:                return .client
        case .busy, .streaming:   return .server
        case .done:               return .nobody
        }
    }
}

// MARK: - Transitions

extension BlockFetchState {
    func afterSend(_ message: BlockFetchMessage) throws -> BlockFetchState {
        switch (self, message) {
        case (.idle, .requestRange): return .busy
        case (.idle, .clientDone):   return .done
        default:
            throw ProtocolError.invalidTransition(
                protocol: "blockFetch",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }

    func afterReceive(_ message: BlockFetchMessage) throws -> BlockFetchState {
        switch (self, message) {
        case (.busy, .startBatch):       return .streaming
        case (.busy, .noBlocks):         return .idle
        case (.streaming, .block):       return .streaming
        case (.streaming, .batchDone):   return .idle
        default:
            throw ProtocolError.invalidTransition(
                protocol: "blockFetch",
                state: String(describing: self),
                message: String(describing: message)
            )
        }
    }
}
