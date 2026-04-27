import Foundation

/// The high-level lifecycle of a peer's connection (no protocol state).
///
/// Mirrors `pallas-network2`'s `ConnectionState`. The transitions are:
/// ```
/// .new → .connecting → .connected → .initialized
///                    ↘ .errored ↘ .disconnected
/// ```
///
/// `.errored` carries the underlying error so the governor can surface it on
/// `GovernorEvent.peerDisconnected(_:reason:)`.
public enum ConnectionState: @unchecked Sendable {
    /// Discovered but no connection attempted.
    case new
    /// Dial in progress.
    case connecting
    /// TCP up, handshake not yet complete.
    case connected
    /// Handshake done, mini-protocols may run.
    case initialized
    /// Cleanly closed.
    case disconnected
    /// Connection failed at some stage; carries the cause.
    case errored(Error)
}

extension ConnectionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .new:           return "new"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .initialized:   return "initialized"
        case .disconnected:  return "disconnected"
        case .errored(let e): return "errored(\(e))"
        }
    }
}

extension ConnectionState {
    /// Tag-only equality. Two `.errored` states compare equal regardless of the
    /// inner error value, since errors are not generally `Equatable`.
    public static func ~= (pattern: ConnectionState, value: ConnectionState) -> Bool {
        switch (pattern, value) {
        case (.new, .new),
             (.connecting, .connecting),
             (.connected, .connected),
             (.initialized, .initialized),
             (.disconnected, .disconnected),
             (.errored, .errored):
            return true
        default:
            return false
        }
    }
}
