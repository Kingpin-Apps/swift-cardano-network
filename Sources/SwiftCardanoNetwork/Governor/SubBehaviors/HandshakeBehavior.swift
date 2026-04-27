/// Configuration for `HandshakeBehavior`.
///
/// Mirrors the shape of `ProtocolConfig` for the Handshake-relevant fields,
/// so callers configuring the governor can reuse the same values they would
/// pass to the per-connection facade.
public struct HandshakeBehaviorConfig: Sendable {
    /// Network magic for the Cardano network (mainnet, preview, preprod, ...).
    public var networkMagic: UInt32

    /// NtN versions to propose, highest-preferred first. The default mirrors
    /// `ProtocolConfig.ntnVersions`.
    public var ntnVersions: [UInt16]

    /// Local advertised peer-sharing willingness (§3.11). `1` = enabled, `0`
    /// = disabled. Only included in version data for v11+.
    public var peerSharingFlag: UInt8

    /// Whether to advertise as initiator-only (no responder protocols).
    public var initiatorOnly: Bool

    public init(
        networkMagic: UInt32,
        ntnVersions: [UInt16] = [14, 13, 12, 11, 10, 9, 8, 7],
        peerSharingFlag: UInt8 = 1,
        initiatorOnly: Bool = false
    ) {
        self.networkMagic = networkMagic
        self.ntnVersions = ntnVersions
        self.peerSharingFlag = peerSharingFlag
        self.initiatorOnly = initiatorOnly
    }
}

/// Sub-behavior that drives the NtN Handshake mini-protocol within the
/// `OutboundGovernor`.
///
/// On `connected` (TCP up, handshake not yet attempted) the visitor emits
/// `MsgProposeVersions` with the configured version map.
///
/// On `inboundMessage`, after the apply layer has advanced
/// `state.handshake` based on the received message, the visitor:
/// - On `state.handshake == .accepted`: transitions `state.connection` to
///   `.initialized` and emits `GovernorEvent.peerConnected(_, version)`.
///   Requires `state.negotiatedVersion` to have been set by the apply layer.
/// - On `state.handshake == .refused`: transitions `state.connection` to
///   `.errored(HandshakeRefusedError())`. The apply layer is expected to
///   have stashed the actual `RefuseReason` (see Phase 13.7); for now we
///   surface a generic refusal so `ConnectionBehavior` will follow up with
///   a disconnect.
public struct HandshakeBehavior: PeerVisitor {

    public var config: HandshakeBehaviorConfig

    public init(config: HandshakeBehaviorConfig) {
        self.config = config
    }

    // MARK: - PeerVisitor

    public mutating func connected(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        // Only kick off when the state machine is in its initial position
        // and we have not yet sent ProposeVersions.
        guard state.handshake == .start else { return }

        let versions = buildVersionMap()
        outbound.push(.send(pid, .handshake(.proposeVersions(versions))))
    }

    public mutating func inboundMessage(
        _ pid: PeerID,
        _ state: inout PeerState,
        _ outbound: inout OutboundQueue
    ) {
        // Transitions only fire from .connected — gated so subsequent inbound
        // traffic on the same peer doesn't re-emit `peerConnected`.
        guard case .connected = state.connection else { return }

        switch state.handshake {
        case .accepted:
            guard let neg = state.negotiatedVersion else { return }
            state.connection = .initialized
            outbound.push(.peerConnected(pid, neg))

        case .refused:
            state.connection = .errored(
                HandshakeRefusedError(reason: state.lastHandshakeRefusal)
            )

        case .start, .proposed:
            break
        }
    }

    // MARK: - Helpers

    private func buildVersionMap() -> [UInt16: HandshakeVersionData] {
        var map: [UInt16: HandshakeVersionData] = [:]
        for v in config.ntnVersions {
            let peerSharing: UInt8? = v >= NodeToNodeVersion.v11 ? config.peerSharingFlag : nil
            let query: Bool? = v >= NodeToNodeVersion.v13 ? false : nil
            map[v] = .nodeToNode(
                networkMagic: config.networkMagic,
                initiatorOnly: config.initiatorOnly,
                peerSharing: peerSharing,
                query: query
            )
        }
        return map
    }
}

/// Error placed in `state.connection` when the remote refused our proposed
/// version map. Carries the typed `RefuseReason` reported by the peer, when
/// available — the apply layer captures it from the inbound `MsgRefuse`
/// before transitioning the handshake state machine.
///
/// `reason` is `nil` only in pre-Phase-13.8 code paths or when the apply
/// layer was bypassed (e.g. tests setting `state.handshake = .refused`
/// directly).
public struct HandshakeRefusedError: Error, Sendable, CustomStringConvertible {
    public let reason: RefuseReason?

    public init(reason: RefuseReason? = nil) {
        self.reason = reason
    }

    public var description: String {
        if let reason {
            return "handshake refused: \(reason)"
        }
        return "handshake refused"
    }
}
