/// Configuration for `ConnectionBehavior`. Currently empty — kept as a struct
/// to mirror pallas's API and leave room for future tunables (per-peer dial
/// retry, reconnect backoff, etc.).
public struct ConnectionBehaviorConfig: Sendable {
    public init() {}
}

/// Sub-behavior that drives TCP connect/disconnect commands based on the
/// governor's promotion + connection state. Mirrors `pallas-network2`'s
/// `ConnectionBehavior`.
///
/// ## Decision matrix
///
/// **`needsConnection`** fires when we should dial a peer:
/// connection is `.new` or `.disconnected` AND promotion is `.warm`/`.hot`.
///
/// **`needsDisconnect`** fires when we should tear a connection down:
/// connection is `.errored`, OR connection is `.connected`/`.initialized` but
/// promotion is `.cold`/`.banned`.
///
/// Both decisions are evaluated on every housekeeping tick. The `errored`
/// visitor hook fires an additional disconnect when the governor reports an
/// error event for a peer.
public struct ConnectionBehavior: PeerVisitor {

    public var config: ConnectionBehaviorConfig

    /// Total `connect` commands emitted (lifetime). Useful for tests and
    /// observability — pallas uses an OpenTelemetry counter; we expose a
    /// plain integer so callers can wire whatever metric they prefer.
    public private(set) var connectionAttempts: Int = 0

    public init(config: ConnectionBehaviorConfig = .init()) {
        self.config = config
    }

    // MARK: - Predicates

    static func needsConnection(_ state: PeerState) -> Bool {
        switch state.connection {
        case .connected, .connecting, .initialized, .errored:
            return false
        case .new, .disconnected:
            switch state.promotion {
            case .warm, .hot:    return true
            case .cold, .banned: return false
            }
        }
    }

    static func needsDisconnect(_ state: PeerState) -> Bool {
        switch state.connection {
        case .errored:
            return true
        case .new, .connecting, .disconnected:
            return false
        case .connected, .initialized:
            switch state.promotion {
            case .cold, .banned: return true
            case .warm, .hot:    return false
            }
        }
    }

    // MARK: - PeerVisitor

    public mutating func housekeeping(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        if Self.needsConnection(state) {
            state.connection = .connecting
            outbound.push(.connect(pid))
            connectionAttempts += 1
            CardanoMetrics
                .counter(CardanoMetrics.governorConnectionAttemptsTotal)
                .increment()
        }

        if Self.needsDisconnect(state) {
            outbound.push(.disconnect(pid))
        }
    }

    public mutating func errored(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        if Self.needsDisconnect(state) {
            outbound.push(.disconnect(pid))
        }
    }
}
