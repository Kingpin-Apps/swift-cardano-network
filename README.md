# swift-cardano-network

A Swift implementation of the Cardano [Ouroboros](https://iohk.io/en/research/library/papers/ouroboros-a-provably-secure-proof-of-stake-blockchain-protocol/) networking stack. Provides both Node-to-Client (NtC) and Node-to-Node (NtN) connectivity to Cardano blockchain nodes using a fully async/await API built on [SwiftNIO](https://github.com/apple/swift-nio).

## Requirements

- Swift 6.0+
- macOS 14+ or iOS 17+

## Installation

Add the package to your `Package.swift`. The typed API (decoded `EraBlock`, `Transaction`, `UTxO`, etc.) requires `SwiftCardanoCore` alongside `SwiftCardanoNetwork`.

```swift
dependencies: [
    .package(url: "https://github.com/Kingpin-Apps/swift-cardano-network.git", from: "1.0.0"),
    .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.3.15"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SwiftCardanoNetwork", package: "swift-cardano-network"),
            .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
        ]
    )
]
```

## Overview

The library implements the full Ouroboros mini-protocol suite over a multiplexed TCP or Unix domain socket connection. All mini-protocols expose a **typed API** backed by [SwiftCardanoCore](https://github.com/Kingpin-Apps/swift-cardano-core) that works with fully-decoded `EraBlock`, `Transaction`, `UTxO`, and `ProtocolParameters` values — no manual CBOR handling required. A lower-level raw API is also available for advanced use cases.

The top-level entry point is `CardanoNode`, which provides factory methods for both manual and scoped (automatically closed) connections:

| Factory                                | Transport         | Use case                                     |
| -------------------------------------- | ----------------- | -------------------------------------------- |
| `CardanoNode.withClient(config:body:)` | Unix socket (NtC) | **Preferred** — scoped, closes automatically |
| `CardanoNode.withNode(config:body:)`   | TCP (NtN)         | **Preferred** — scoped, closes automatically |
| `CardanoNode.connectToClient(config:)` | Unix socket (NtC) | Manual lifetime management                   |
| `CardanoNode.connectToNode(config:)`   | TCP (NtN)         | Manual lifetime management                   |

All factory methods perform the Handshake negotiation automatically.

---

## Quick Start

### Node-to-Client (local node)

Connect to a running `cardano-node` process via its Unix socket to get full block data, submit transactions, query ledger state, and inspect the mempool.

```swift
import SwiftCardanoNetwork

var config = CardanoNetworkConfiguration.mainnet
config.connection.socketPath = "/ipc/node.socket"

try await CardanoNode.withClient(config: config) { connection in
    // Stream full decoded blocks (requires SwiftCardanoCore)
    for try await event in connection.follow() {
        switch event {
        case .rollForward(let eraBlock, let tip):
            // eraBlock is EraBlock — switch on era for full type access
            print("Tip block \(tip.blockNo)")
        case .rollBackward(let point, _):
            print("Rollback to \(point)")
        }
    }
} // connection closed automatically
```

### Node-to-Node (remote peer)

Connect to a remote Cardano relay peer over TCP to stream block headers and participate in transaction propagation.

```swift
import SwiftCardanoNetwork

try await CardanoNode.withNode(config: .mainnet) { connection in
    // Stream decoded block headers (full bodies require BlockFetch)
    for try await event in connection.follow() {
        if case .rollForward(let eraHeader, let tip) = event {
            print("Tip: \(tip.blockNo)")
        }
    }
} // connection closed automatically
```

---

## Configuration

### Built-in Network Presets

```swift
// Cardano Mainnet
let config = CardanoNetworkConfiguration.mainnet

// Preview testnet
let config = CardanoNetworkConfiguration.preview

// Pre-production testnet
let config = CardanoNetworkConfiguration.preprod
```

### Programmatic Configuration

```swift
var config = CardanoNetworkConfiguration()
config.connection.socketPath      = "/ipc/node.socket"   // NtC: Unix socket path
config.connection.host            = "relay.example.com"  // NtN: remote host
config.connection.port            = 3001                 // NtN: remote port
config.connection.networkMagic    = 764_824_073          // Mainnet magic
config.connection.connectTimeoutSeconds = 10.0
```

### Loading from a JSON File

```swift
let config = try CardanoNetworkConfiguration.load(fromFile: "/etc/cardano/config.json")
```

Example `config.json`:

```json
{
  "connection": {
    "socketPath": "/ipc/node.socket",
    "networkMagic": 764824073
  },
  "logging": {
    "level": "info"
  },
  "metrics": {
    "enabled": true
  }
}
```

### Environment Variable Overrides

Call `mergedWithEnvironment()` to overlay environment variables on top of any base configuration:

```swift
let config = CardanoNetworkConfiguration.mainnet.mergedWithEnvironment()
// or load from file and apply env overrides:
let config = try CardanoNetworkConfiguration.load(fromFile: "/etc/cardano/config.json",
                                                   mergedWithEnvironment: true)
// or build entirely from environment variables:
let config = CardanoNetworkConfiguration.loadFromEnvironment()
```

| Variable                          | Config field                       |
| --------------------------------- | ---------------------------------- |
| `CARDANO_NETWORK_SOCKET_PATH`     | `connection.socketPath`            |
| `CARDANO_NETWORK_HOST`            | `connection.host`                  |
| `CARDANO_NETWORK_PORT`            | `connection.port`                  |
| `CARDANO_NETWORK_MAGIC`           | `connection.networkMagic`          |
| `CARDANO_NETWORK_CONNECT_TIMEOUT` | `connection.connectTimeoutSeconds` |
| `CARDANO_NETWORK_LOG_LEVEL`       | `logging.level`                    |
| `CARDANO_NETWORK_METRICS_ENABLED` | `metrics.enabled`                  |

### Protocol Configuration

```swift
var config = CardanoNetworkConfiguration.mainnet
config.protocol.ntnVersions             = [14, 13]  // NtN Handshake versions (highest preferred)
config.protocol.ntcVersions             = [16, 15]  // NtC Handshake versions
config.protocol.keepAliveIntervalSeconds = 60.0
config.protocol.keepAliveTimeoutSeconds  = 10.0
```

---

## Mini-Protocols

### ChainSync

NtC delivers **full decoded blocks** via `follow()`; NtN delivers **decoded block headers** via `follow()`. Both return `AsyncThrowingStream`. The same method name is used in both cases — the return type differs (`EraBlockEvent` for NtC, `EraHeaderEvent` for NtN).

**NtC — full blocks:**

```swift
// Follow from the current tip (no intersection point needed)
for try await event in connection.follow() {
    switch event {
    case .rollForward(let eraBlock, let tip):
        // Switch on era to access era-specific fields
        switch eraBlock {
        case .conway(let block):
            print("Conway txs=\(block.transactionBodies.count) tip=\(tip.blockNo)")
        case .babbage(let block):
            print("Babbage txs=\(block.transactionBodies.count)")
        default:
            print("Other era block, tip=\(tip.blockNo)")
        }
    case .rollBackward(let point, _):
        print("Rollback to \(point)")
    }
}

// Follow from a known intersection point to avoid re-syncing
let knownPoint = Point.blockPoint(slot: 50_000_000, hash: knownHashBytes)
for try await event in connection.follow(from: [knownPoint]) { ... }
```

`EraBlockEvent` cases:
- `.rollForward(EraBlock, Tip)` — new decoded era-tagged block available
- `.rollBackward(Point, Tip)` — chain rolled back; resync from `point`

The convenience method `connection.follow(from:)` is also available directly on `NodeToClientConnection`.

**NtN — block headers only:**

```swift
for try await event in connection.follow() {
    switch event {
    case .rollForward(let eraHeader, let tip):
        switch eraHeader {
        case .shelley(let header), .allegra(let header), .mary(let header),
             .alonzo(let header), .babbage(let header), .conway(let header):
            print("Slot: \(header.headerBody.slot), tip: \(tip.blockNo)")
        case .byron:
            print("Byron header, tip: \(tip.blockNo)")
        }
    case .rollBackward(let point, _):
        print("Rollback to \(point)")
    }
}
```

`EraHeaderEvent` cases:
- `.rollForward(EraBlockHeader, Tip)` — new decoded era-tagged block header available
- `.rollBackward(Point, Tip)` — chain rolled back; resync from `point`

Breaking out of a `for try await` loop or cancelling the enclosing `Task` terminates the stream cleanly.

### BlockFetch (NtN only)

Downloads complete block bodies for a range of chain points. Use this after ChainSync delivers a header over an NtN connection. The typed overload returns decoded `EraBlock` values directly.

```swift
let blocks: [EraBlock] = try await connection.fetch(
    from: .blockPoint(slot: 1_000_000, hash: startHash),
    to:   .blockPoint(slot: 1_001_000, hash: endHash)
)

for block in blocks {
    if case .conway(let b) = block {
        print("Transactions: \(b.transactionBodies.count)")
    }
}
```

The `blockFetch.fetch(from:to:)` overload without `SwiftCardanoCore` returns `[ByteBuffer]` (raw CBOR), one buffer per block. Throws `BlockFetchError.emptyBatch` if the node has no blocks in the requested range.

### LocalTxSubmission (NtC only)

Submit a signed `Transaction` to a local node. Pass a fully-typed `Transaction` from `swift-cardano-core` — serialisation is handled automatically. The `era` parameter is a `SwiftCardanoCore.Era` enum value and defaults to `.conway`.

```swift
// Submit (throws LocalTxSubmissionError.rejected on rejection)
try await connection.submit(signedTx)

// Submit and capture the TransactionId
let txId = try await connection.submitChecked(signedTx)
print("Accepted: \(txId)")

// Catch rejection details
do {
    try await connection.submit(signedTx)
} catch LocalTxSubmissionError.rejected(let rejection) {
    // rejection.era is a typed Era value, e.g. .conway, .babbage, etc.
    print("Rejected — era=\(rejection.era) reason: \(rejection.humanReadable)")
}

// Submit for an earlier era explicitly using the Era enum
try await connection.txSubmission.submit(signedTx, era: .babbage)
```

The `Era` enum covers all Cardano eras and maps to the wire tag used by the Ouroboros protocol:

| Era        | Wire tag |
| ---------- | -------- |
| `.byron`   | 0        |
| `.shelley` | 1        |
| `.allegra` | 2        |
| `.mary`    | 3        |
| `.alonzo`  | 4        |
| `.babbage` | 5        |
| `.conway`  | 6        |

`TxRejection` also provides a `humanReadable` property that renders the rejection reason as a human-readable string, and `decodedPrimitive()` for walking the raw CBOR structure.

### LocalStateQuery (NtC only)

Query the ledger state at the volatile tip. All common queries have typed convenience methods that return decoded SwiftCardanoCore values directly.

```swift
// UTxO by address
let utxos = try await connection.queryUTxO(for: [address])
for utxo in utxos {
    print("\(utxo.input.transactionId)#\(utxo.input.index) → \(utxo.output.amount)")
}

// UTxO by transaction inputs
let utxos = try await connection.queryUTxO(for: [txInput])

// Protocol parameters
let params = try await connection.queryProtocolParameters()
print("Min fee A: \(params.minFeeA)")

// Ledger tip
let tip = try await connection.queryLedgerTip()

// Current epoch
let epoch = try await connection.queryEpochNo()
print("Epoch: \(epoch)")

// Governance state (Conway) — returns typed GovernanceState
let govState = try await connection.queryGovernanceState()
```

All convenience methods are available both via `connection.stateQuery.*` and as top-level shorthand on `NodeToClientConnection`. Each call acquires a ledger snapshot, runs the query, then releases the snapshot automatically.

The full typed query surface includes (selected):

| Method | Returns |
| ------ | ------- |
| `queryUTxO(for:)` | `[UTxO]` |
| `queryWholeUTxO()` | `[UTxO]` (⚠ large on mainnet) |
| `queryProtocolParameters()` | `ProtocolParameters` |
| `queryProposedProtocolParametersUpdates()` | `ProposedProtocolParamUpdates` |
| `queryFuturePParams()` | `ProtocolParameters?` |
| `queryLedgerTip()` | `Point` |
| `queryEpochNo()` | `EpochNumber` |
| `queryPoolDistr(_:)` | `PoolDistr` |
| `queryStakePools()` | `StakePools` |
| `queryStakePoolParams(for:)` | `StakePoolParams` |
| `queryPoolState(_:)` | `PoolState` |
| `queryStakeSnapshots(for:)` | `StakeSnapshots` |
| `queryNonMyopicMemberRewards(_:)` | `NonMyopicMemberRewards` |
| `queryRewardInfoPools()` | `RewardInfoPools` |
| `queryFilteredDelegationsAndRewardAccounts(_:)` | `FilteredDelegationsAndRewards` |
| `queryGovernanceState()` | `GovernanceState` |
| `queryConstitution()` | `LedgerConstitution` |
| `queryRatifyState()` | `RatifyState` |
| `queryAccountState()` | `AccountState` |
| `queryDRepState(_:)` | `DRepState` |
| `queryDRepStakeDistr(_:)` | `DRepStakeDistribution` |
| `queryCommitteeMembersState(_:)` | `CommitteeMembersState` |
| `queryProposals(_:)` | `ActiveProposals` |
| `queryGenesisConfig()` | `GenesisConfig` |
| `queryBigLedgerPeerSnapshot()` | `BigLedgerPeerSnapshot` |
| `queryCurrentEpochState()` | `CurrentEpochState` |
| `queryDebugLedgerState()` | `DebugLedgerState` |
| `queryProtocolState()` | `ChainDepState` |

### LocalTxMonitor (NtC only)

Inspect the node's local mempool — enumerate pending transactions as decoded `Transaction` values, check for a specific transaction, and read capacity metrics.

```swift
// Snapshot the entire mempool — returns a MempoolSnapshot (slot + decoded Transactions)
let snapshot = try await connection.snapshotMempool()
print("Mempool at slot \(snapshot.slotNo): \(snapshot.txs.count) transaction(s)")
for tx in snapshot.txs {
    print("  tx id: \(tx.id?.description ?? "unknown")")
}

// Check whether a specific transaction is pending (takes a TransactionId)
let present = try await connection.hasTx(txId)

// Read mempool size metrics
let capacity = try await connection.mempoolSizes()
print("Capacity: \(capacity.capacityInBytes) bytes, \(capacity.numberOfTxs) txs")

// Read extended mempool measure data
let measures = try await connection.mempoolMeasures()
for m in measures.measures {
    print("\(m.key): \(m.current) / \(m.capacity)")
}
```

`connection.snapshotMempool()` returns `MempoolSnapshot(slotNo: UInt64, txs: [Transaction])`. The raw `txMonitor.snapshot()` returns `(slotNo: UInt64, txs: [MempoolTx])` if you need to decode manually.

### TxSubmission2 (NtN only)

Pull-based transaction propagation with a remote peer. Implement the `TxSubmissionProvider` protocol to serve transactions from your mempool when the remote peer requests them.

```swift
try await connection.serveTransactions(provider: myMempool)
```

### PeerSharing (NtN only)

Request peer addresses from a remote peer that has enabled peer sharing (NtN v14+). This protocol is used by the `OutboundGovernor` automatically when peer sharing is enabled.

```swift
// peerSharing() is a throwing factory — it checks version and peer-sharing flag
let ps = try connection.peerSharing()
let peers = try await ps.request(amount: 10)
for peer in peers {
    print("Discovered: \(peer.host):\(peer.port)")
}
try await ps.done()
```

Enable peer sharing in the handshake by setting `config.protocol.peerSharing = 1` before connecting.

### Dummy Protocols (testing / demos)

Two dummy mini-protocols defined in §3.5 of the Ouroboros Network Specification are available for demos and integration tests. They are **not** part of the Node-to-Node or Node-to-Client protocol suites and are reserved on mux IDs `0x7FFE` (Ping-Pong) and `0x7FFD` (Request-Response).

**Ping-Pong** (§3.5.1) — minimal liveness check; the client sends `ping`, the server replies `pong`.

```swift
let client = PingPongClient(channel: channel, demux: demux)
try await client.ping()        // single round-trip
try await client.run(count: 5) // 5 round-trips, then done
```

**Request-Response** (§3.5.2) — polymorphic single-shot request/reply protocol. Supply a `ReqRespCodec` with encode/decode closures for your payload types, or use `ReqRespCodec<ByteBuffer, ByteBuffer>.raw()` for raw bytes.

```swift
let client = ReqRespClient<ByteBuffer, ByteBuffer>(
    channel: channel,
    demux: demux,
    codec: ReqRespCodec.raw()
)
var req = channel.allocator.buffer(capacity: 4)
req.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
let response = try await client.request(req)
try await client.done()
```

**Handshake-less factories** — because the dummy protocols do not require version negotiation, `CardanoNode` exposes factories that skip the Handshake step entirely. NtN additionally skips the background KeepAlive probe loop, since a peer speaking only dummy protocols would not respond to keep-alive probes.

```swift
// Unix-socket NtC with no handshake
try await CardanoNode.withClientWithoutHandshake(config: config) { connection in
    let response = try await connection.requestResponse(
        request, codec: ReqRespCodec.raw()
    )
}

// TCP NtN with no handshake and no KeepAlive
try await CardanoNode.withNodeWithoutHandshake(config: config) { connection in
    try await connection.runPingPong(count: 10)
}
```

The non-scoped `CardanoNode.connectToClientWithoutHandshake(config:)` and `connectToNodeWithoutHandshake(config:)` variants are also available when you need manual lifetime management.

---

## Outbound Governor (multi-peer)

For workloads that need to hold many peers concurrently — block producers, explorers, relay nodes — the library provides `OutboundGovernor`, a multi-peer controller that manages Cold → Warm → Hot peer promotion, peer-sharing-driven discovery, and reputation-based banning.

```swift
import NIOPosix
import SwiftCardanoNetwork

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let interface = NIOInterface(group: group)

let governor = OutboundGovernor(
    interface: interface,
    handshakeConfig: HandshakeBehaviorConfig(networkMagic: 764_824_073),
    promotionConfig: PromotionConfig(maxPeers: 50, maxWarmPeers: 20, maxHotPeers: 5)
)

await governor.start()

// Seed with known relays
for seed in knownRelays {
    await governor.includePeer(PeerID(host: seed.host, port: seed.port))
}

// Run housekeeping on a cadence
Task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        await governor.housekeeping()
    }
}

// Consume events
for await event in governor.events {
    switch event {
    case .peerConnected(let pid, let version):
        print("Connected: \(pid) v\(version.version)")
    case .peerBanned(let pid, let reason):
        print("Banned: \(pid) — \(reason)")
    default:
        break
    }
}
```

See the [OutboundGovernor article in DocC](Sources/SwiftCardanoNetwork/SwiftCardanoNetwork.docc/Articles/OutboundGovernor.md) for the full API, configuration knobs, and a discussion of when to use the governor vs. the single-connection facade.

---

## Connection Lifecycle

The preferred way to manage a connection is the scoped `withClient` / `withNode` pattern. The connection is closed automatically when the closure returns, whether it exits normally or throws — analogous to Python's `with` statement or Swift's own `withTaskGroup`:

```swift
try await CardanoNode.withClient(config: config) { connection in
    // ... use connection ...
} // closed here, even if an error was thrown
```

For cases where you need to manage the lifetime manually (e.g. storing the connection as a property), use the `connect` factories directly and call `close()` yourself:

```swift
let connection = try await CardanoNode.connectToClient(config: config)
// ... use connection ...
await connection.close()
```

`close()` is `async` — it cannot be called in a `defer` body. It is safe to call multiple times.

---

## Observability

### Logging

The library uses [swift-log](https://github.com/apple/swift-log) with structured metadata on all important events. Bootstrap your preferred log handler before opening connections:

```swift
import Logging

LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

// Adjust the library's minimum log level
var config = CardanoNetworkConfiguration.mainnet
config.logging.level       = .debug
config.logging.labelPrefix = "my-app.cardano"
```

Two additional log handlers are included for convenience:

- `FileLogHandler` — writes structured log output to a rotating log file.
- `SystemLogHandler` — writes to the platform system log (OSLog on Apple platforms, syslog on Linux).

### Metrics

All mini-protocols emit [swift-metrics](https://github.com/apple/swift-metrics)-compatible metrics. Bootstrap a metrics backend (e.g. `prometheus-client-swift`) in your app startup:

| Metric                                           | Type    | Description                                          |
| ------------------------------------------------ | ------- | ---------------------------------------------------- |
| `cardano_network_bytes_received_total`           | Counter | Total bytes received                                 |
| `cardano_network_bytes_sent_total`               | Counter | Total bytes sent                                     |
| `cardano_network_connections_total`              | Counter | Total connections opened                             |
| `cardano_network_connections_active`             | Gauge   | Currently open connections                           |
| `cardano_network_handshake_total`                | Counter | Handshake completions                                |
| `cardano_network_handshake_duration_seconds`     | Timer   | Handshake latency                                    |
| `cardano_network_blocks_received_total`          | Counter | Blocks received via ChainSync                        |
| `cardano_network_rollbacks_total`                | Counter | Chain rollback events                                |
| `cardano_network_tx_submissions_total`           | Counter | Tx submission attempts (`result=accepted\|rejected`) |
| `cardano_network_tx_submission_duration_seconds` | Timer   | Tx submission latency                                |
| `cardano_network_query_duration_seconds`         | Timer   | LocalStateQuery latency                              |
| `cardano_network_block_fetch_duration_seconds`   | Timer   | BlockFetch range download latency                    |
| `cardano_network_keepalive_rtt_seconds`          | Timer   | KeepAlive round-trip time                            |
| `cardano_network_mempool_tx_count`               | Gauge   | Transactions in mempool snapshot                     |
| `cardano_network_mempool_capacity_bytes`         | Gauge   | Mempool capacity in bytes                            |
| `cardano_network_chain_tip_slot`                 | Gauge   | Chain tip slot number                                |
| `cardano_network_chain_tip_block`                | Gauge   | Chain tip block number                               |
| `cardano_network_sdu_decode_errors_total`        | Counter | Mux frame decode failures                            |
| `cardano_network_agency_violations_total`        | Counter | Protocol agency violations                           |

Governor-specific metrics are documented in the OutboundGovernor article.

---

## Architecture

```
CardanoNode (factory)
├── connectToClient()  →  NodeToClientConnection
│       ├── chainSync       (ChainSyncClient — full EraBlocks)
│       ├── txSubmission    (LocalTxSubmissionClient)
│       ├── stateQuery      (LocalStateQueryClient)
│       └── txMonitor       (LocalTxMonitorClient)
│
└── connectToNode()    →  NodeToNodeConnection
        ├── chainSync       (ChainSyncClient — EraBlockHeaders)
        ├── blockFetch      (BlockFetchClient)
        ├── txSubmission2   (TxSubmission2Client)
        └── peerSharing     (PeerSharingClient)

OutboundGovernor (multi-peer, NtN)
├── peers: [PeerID: PeerState]    (cold / warm / hot / banned)
├── interface: any Interface      (NIOInterface or EmulatedInterface)
└── visitors: HandshakeBehavior, KeepAliveBehavior, DiscoveryBehavior,
              PromotionBehavior, ConnectionBehavior, PeerSharingResponderBehavior
```

**Transport layer** (`Transport/`) — `UnixSocketTransport` and `TCPTransport` wrap SwiftNIO channels and produce a `(Channel, DemuxHandler)` tuple.

**Mux layer** (`Mux/`) — `MuxFrameDecoder` and `MuxFrameEncoder` implement the Ouroboros SDU framing. `DemuxHandler` routes inbound frames to the correct mini-protocol stream by protocol ID.

**Protocol Driver** (`Driver/`) — `ProtocolDriver` wraps a channel and a state machine, sending and receiving type-safe messages. Each client creates a fresh driver per operation.

**Mini-protocols** (`Protocols/`) — Each sub-folder contains:
- `*Messages.swift` — CBOR-tagged message types
- `*StateMachine.swift` — Agency-based state machine
- `*Codec.swift` — CBOR encode/decode
- `*Client.swift` — Public async API
- `*Client+Typed.swift` — SwiftCardanoCore typed overloads (where applicable)

**Governor** (`Governor/`) — `OutboundGovernor` actor plus six sub-behaviour types and the `Interface` / `NIOInterface` I/O abstraction.

---

## Testing

Run the full test suite (890+ tests):

```bash
swift test
```

Run only a specific test target:

```bash
swift test --filter SwiftCardanoNetworkTests.MuxTests
```

Integration tests in `Tests/SwiftCardanoNetworkTests/Integration/` use an embedded `MockCardanoNode` and do not require a running `cardano-node`.

---

## License

See [LICENSE](LICENSE) for details.
