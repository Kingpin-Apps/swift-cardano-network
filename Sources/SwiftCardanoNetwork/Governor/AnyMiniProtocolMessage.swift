/// A wire-level NtN mini-protocol message, regardless of which protocol it
/// belongs to. The `OutboundGovernor` routes inbound and outbound traffic
/// uniformly through this enum so the visitor pipeline can dispatch on it
/// without owning per-protocol channels.
///
/// `AnyMiniProtocolMessage` carries the same payload as the underlying
/// per-protocol message types — it is a tagged union, not a re-encoding.
public enum AnyMiniProtocolMessage: Sendable {
    case handshake(HandshakeMessage)
    case keepAlive(KeepAliveMessage)
    case peerSharing(PeerSharingMessage)
    case chainSync(ChainSyncMessage)
    case blockFetch(BlockFetchMessage)
    case txSubmission2(TxSubmission2Message)
}

extension AnyMiniProtocolMessage {
    /// The 15-bit mini-protocol number this message belongs on the wire.
    public var protocolID: UInt16 {
        switch self {
        case .handshake:      return MuxSDU.ProtocolID.handshake
        case .keepAlive:      return MuxSDU.ProtocolID.keepAlive
        case .peerSharing:    return MuxSDU.ProtocolID.peerSharing
        case .chainSync:      return MuxSDU.ProtocolID.chainSync
        case .blockFetch:     return MuxSDU.ProtocolID.blockFetch
        case .txSubmission2:  return MuxSDU.ProtocolID.txSubmission2
        }
    }

    /// Short tag for logs / diagnostics.
    public var protocolName: String {
        switch self {
        case .handshake:      return "handshake"
        case .keepAlive:      return "keepAlive"
        case .peerSharing:    return "peerSharing"
        case .chainSync:      return "chainSync"
        case .blockFetch:     return "blockFetch"
        case .txSubmission2:  return "txSubmission2"
        }
    }
}
