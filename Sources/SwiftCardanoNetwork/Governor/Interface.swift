/// An I/O abstraction that the `OutboundGovernor` drives via commands and
/// observes via events. Mirrors `pallas-network2`'s `Interface` trait.
///
/// The Interface is responsible for:
/// 1. Executing every `InterfaceCommand` it receives — opening TCP
///    connections, encoding and writing mini-protocol messages, and tearing
///    connections down on `disconnect`.
/// 2. Emitting an `InterfaceEvent` whenever something happens that the
///    governor needs to react to — a peer connected, a message arrived,
///    an error occurred, or a peer was disconnected.
///
/// The split lets governor logic stay testable without sockets: the test
/// harness implements `Interface` over an in-memory channel
/// (`EmulatedInterface`) while the production path uses
/// `NIOInterface` (added in Phase 13.7).
///
/// **Single-consumer**: the `events` stream is intended to be consumed by
/// exactly one task (typically the governor's main loop). Calling the
/// getter more than once produces the same underlying continuation.
public protocol Interface: Sendable {
    /// Execute a command issued by the governor. The Interface is free to
    /// delay or coalesce work as long as commands' observable side-effects
    /// remain in issue order *per peer*.
    func dispatch(_ command: InterfaceCommand) async

    /// The single inbound event stream. Drive the governor's main loop by
    /// `for await event in interface.events`.
    var events: AsyncStream<InterfaceEvent> { get }
}

/// Inbound events the `Interface` reports up to the `OutboundGovernor`.
public enum InterfaceEvent: Sendable {
    /// TCP connection established — handshake not yet attempted.
    case connected(PeerID)

    /// Handshake completed successfully and mini-protocols may run.
    case initialized(PeerID, NegotiatedVersion)

    /// A wire message arrived from the peer.
    case messageReceived(PeerID, AnyMiniProtocolMessage)

    /// A connection-level error occurred. The governor will typically
    /// transition the peer to `.errored` and let `ConnectionBehavior`
    /// emit a follow-up disconnect.
    case errored(PeerID, any Error & Sendable)

    /// The connection has been closed (cleanly or after an error).
    case disconnected(PeerID)
}
