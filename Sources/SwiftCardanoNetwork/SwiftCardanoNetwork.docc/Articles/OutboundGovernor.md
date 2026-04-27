# Outbound Governor

A multi-peer controller for production diffusion-style workloads — bootstrap from seed peers, share peers, promote and demote, ban on misbehaviour. Pallas-network2 parity.

## Overview

`SwiftCardanoNetwork` exposes two parallel ways to talk to Cardano peers, and they exist for different problems:

| Use case | Pick this |
|---|---|
| Follow chain from one relay; submit a transaction; query the ledger | ``CardanoNode`` factory + ``NodeToNodeConnection`` / ``NodeToClientConnection`` |
| Hold many peers concurrently, react to peer quality, run §3.11.5 peer-sharing-driven discovery, gracefully demote on errors | ``OutboundGovernor`` |

Both paths share the same wire-codec layer. The governor is **additive** — picking it does not lock you out of the per-connection facade for sub-tasks.

## When to use the governor

Use ``OutboundGovernor`` when you need:

- **Multi-peer policy.** "Connect to 50, keep 10 hot." The governor tracks every peer's promotion tier (cold / warm / hot / banned) and applies the limits in ``PromotionConfig`` on each housekeeping tick.
- **Peer discovery via §3.11.** ``DiscoveryBehavior`` drives `MsgShareRequest` against eligible peers, drains responses into a shared pool, and exposes the pool via ``OutboundGovernor/discoveredPeers()`` so your application can connect to the next batch.
- **Reputation-driven banning.** Peers that commit a wire violation, exceed `errorCount`, or are explicitly banned are removed from cold/warm/hot and never re-promoted on rediscovery.
- **Pluggable I/O for testing.** The ``Interface`` protocol decouples policy logic from sockets — production uses ``NIOInterface``, tests can use the in-memory `EmulatedInterface`.

Stick with ``CardanoNode`` when:

- You just need one stable connection to a known relay (block explorers, indexers, wallets, CLI tools).
- You want the simplest async API: `try await CardanoNode.withNode(config:) { connection in ... }`.
- You don't need to reason about many peers' state at once.

## Architecture

The governor is an `actor` holding a `[PeerID: PeerState]` registry, a stack of six sub-behaviours, and a single shared outbound queue:

```
OutboundGovernor (actor)
│
├── peers: [PeerID: PeerState]
├── interface: any Interface          ← pluggable I/O (NIO or in-memory)
├── outboundQueue: OutboundQueue
├── events: AsyncStream<GovernorEvent>
│
└── visitors (run in this order on every event):
    ├── HandshakeBehavior         — kicks off ProposeVersions, drives accept/refuse
    ├── KeepAliveBehavior         — periodic probes, cookie tracking
    ├── PeerSharingResponderBehavior — surfaces inbound MsgShareRequest
    ├── DiscoveryBehavior         — issues MsgShareRequest, drains replies
    ├── PromotionBehavior         — Cold→Warm→Hot transitions, banning
    └── ConnectionBehavior        — emits .connect / .disconnect
```

The ``Interface`` is the I/O boundary — the governor describes what it wants done (connect to peer, send message, disconnect) and the Interface executes it. ``NIOInterface`` is the production adapter; the test target ships an `EmulatedInterface` for sub-second governor unit tests with no sockets.

## Quick start

```swift
import NIOPosix
import SwiftCardanoNetwork

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let interface = NIOInterface(group: group)

let governor = OutboundGovernor(
    interface: interface,
    handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
    promotionConfig: PromotionConfig(
        maxPeers: 50,
        maxWarmPeers: 20,
        maxHotPeers: 5
    )
)

await governor.start()

// Bootstrap from your seed list.
for seed in [
    PeerID(host: "backbone-1.cardano.iog.io", port: 3001),
    PeerID(host: "backbone-2.cardano.iog.io", port: 3001),
    PeerID(host: "backbone-3.cardano.iog.io", port: 3001),
] {
    await governor.includePeer(seed)
}

// The application owns the housekeeping cadence — there's no internal timer.
let housekeepingTask = Task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)   // 60s
        await governor.housekeeping()
    }
}

// Consume governor events.
for await event in governor.events {
    switch event {
    case .peerConnected(let pid, let version):
        print("connected: \(pid) v\(version.version)")

    case .peerBanned(let pid, let reason):
        print("banned: \(pid) — \(reason)")

    case .peersRequested(let pid, let amount):
        // Pick a subset of the peers you're willing to share and reply.
        let toShare: [PeerAddress] = await myPeerSelectionPolicy(amount: amount)
        await governor.replyPeerShare(pid, peers: toShare)

    case .shareReplyReceived(_, let peers):
        print("learned about \(peers.count) new peers")

    default:
        break
    }
}

housekeepingTask.cancel()
await governor.stop()
await interface.close()
group.shutdownGracefully { _ in }
```

## Configuration knobs

### Promotion limits

``PromotionConfig`` defaults match `pallas-network2`:

```swift
PromotionConfig(
    maxPeers:      100,   // cold + warm + hot
    maxWarmPeers:  50,
    maxHotPeers:   10,
    maxErrorCount: 1      // ban when state.errorCount > limit
)
```

Per the spec §3.11.5 and pallas's choice, `maxErrorCount` is intentionally *strictly greater than*. A peer at the limit is not yet banned; one tick over and it is.

### Discovery aggressiveness

``DiscoveryConfig.highWaterMark`` (default `100`) is both the cap on the discovered pool and the per-request `MsgShareRequest(amount)` ceiling: `amount = highWaterMark - discovered.count`.

### Handshake parameters

``HandshakeBehaviorConfig`` mirrors the relevant ``ProtocolConfig`` fields so callers porting from the per-connection facade can reuse the same values:

```swift
HandshakeBehaviorConfig(
    networkMagic:    764_824_073,
    ntnVersions:     [14, 13, 12, 11, 10, 9, 8, 7],
    peerSharingFlag: 1,    // 0 = PeerSharingDisabled, 1 = PeerSharingEnabled (§3.11.5)
    initiatorOnly:   false
)
```

## What the governor does *not* do

The current scope deliberately omits:

- **Ledger peers** — no LocalStateQuery-driven SPO-relay enumeration. Add manually as initial seeds, or enrich with a `Phase 15`-style LSQ pump that calls ``OutboundGovernor/includePeer(_:)``.
- **DNS resolution** — peer addresses are `host: String` + `port: UInt16`. Resolve hostnames upstream of `includePeer`.
- **Local/public root-peer config files** — no `topology.json` parsing. Construct your own ``PeerID`` set.
- **Big-ledger-peer snapshots** — no §3.13/3.14 signed snapshot support yet.
- **Internal churn timer** — your application calls ``OutboundGovernor/housekeeping()`` on whatever cadence you want. 30–60s is reasonable for production; sub-second is fine in tests.
- **Inbound (responder) connection acceptance** — initiator-only library; we never `bind()`.

## Observability

Sub-behaviours fire counters and gauges via ``CardanoMetrics``:

| Metric | Type | Dimensions | What it counts |
|---|---|---|---|
| `cardano_network_governor_peers_promoted_total` | counter | `transition: cold_to_warm \| warm_to_hot` | promotions across the lifetime |
| `cardano_network_governor_peers_banned_total` | counter | `reason: violation \| error_threshold \| manual` | bans |
| `cardano_network_governor_peers_demoted_total` | counter | — | manual `demotePeer` calls |
| `cardano_network_governor_connection_attempts_total` | counter | — | TCP dial commands emitted |
| `cardano_network_peer_sharing_responder_requests_total` | counter | — | inbound `MsgShareRequest` events |
| `cardano_network_governor_peers_cold/warm/hot/banned` | gauge | — | live tier sizes |

The gauges are pushed on every membership change; counters are incremented on each transition.

## Topics

### Governor

- ``OutboundGovernor``
- ``GovernorEvent``
- ``BanReason``

### Per-peer state

- ``PeerID``
- ``PeerState``
- ``ConnectionState``
- ``PromotionTag``
- ``PeerVisitor``

### Sub-behaviours

- ``DiscoveryBehavior``
- ``DiscoveryConfig``
- ``PromotionBehavior``
- ``PromotionConfig``
- ``ConnectionBehavior``
- ``ConnectionBehaviorConfig``
- ``HandshakeBehavior``
- ``HandshakeBehaviorConfig``
- ``HandshakeRefusedError``
- ``KeepAliveBehavior``
- ``PeerSharingResponderBehavior``

### I/O abstraction

- ``Interface``
- ``InterfaceCommand``
- ``InterfaceEvent``
- ``NIOInterface``
- ``NIOInterfaceError``

### Wire-message routing

- ``AnyMiniProtocolMessage``
- ``OutboundQueue``
