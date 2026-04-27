/// Sub-behavior that drives the KeepAlive mini-protocol (NtN, protocol ID 8)
/// for every initialised peer.
///
/// On each housekeeping tick, for any peer whose connection is `.initialized`
/// and whose KeepAlive state machine is `.idle`, the visitor emits
/// `MsgKeepAlive(cookie)` with a fresh cookie taken from
/// `state.keepAliveNextCookie`. The next cookie counter wraps at
/// `UInt16.max`.
///
/// The application drives the probe cadence by calling
/// `OutboundGovernor.housekeeping()` on its own timer (e.g. every 60s for
/// production, faster for tests). This visitor does not own a timer.
///
/// **Cookie validation** is performed by the governor's inbound-apply layer
/// (Phase 13.7): when an inbound `MsgKeepAliveResponse(cookie)` arrives,
/// the apply layer compares it to `state.keepAliveCookieInFlight`, sets
/// `state.violation = true` on mismatch, and clears the in-flight cookie on
/// success. The visitor itself stays out of validation so it remains pure
/// outbound policy.
public struct KeepAliveBehavior: PeerVisitor {

    public init() {}

    // MARK: - PeerVisitor

    public mutating func housekeeping(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        guard case .initialized = state.connection else { return }
        guard state.keepAlive == .idle else { return }
        guard state.keepAliveCookieInFlight == nil else { return }

        let cookie = state.keepAliveNextCookie
        state.keepAliveNextCookie &+= 1
        state.keepAliveCookieInFlight = cookie
        outbound.push(.send(pid, .keepAlive(.keepAlive(cookie: cookie))))
    }
}
