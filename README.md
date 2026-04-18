# swift-cardano-network

A Swift implementation of the Cardano [Ouroboros](https://iohk.io/en/research/library/papers/ouroboros-a-provably-secure-proof-of-stake-blockchain-protocol/) networking stack. Provides both Node-to-Client (NtC) and Node-to-Node (NtN) connectivity to Cardano blockchain nodes using a fully async/await API built on [SwiftNIO](https://github.com/apple/swift-nio).

## Requirements

- Swift 6.0+
- macOS 14+ or iOS 17+

## Installation

Add the package to your `Package.swift`. The typed API (decoded `Block`, `Transaction`, `UTxO`, etc.) requires `SwiftCardanoCore` alongside `SwiftCardanoNetwork`.

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-cardano-network.git", from: "0.1.0"),
    .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.1.0"),
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

The library implements the full Ouroboros mini-protocol suite over a multiplexed TCP or Unix domain socket connection. All mini-protocols expose a **typed API** backed by [SwiftCardanoCore](https://github.com/Kingpin-Apps/swift-cardano-core) that works with fully-decoded `Block`, `Transaction`, `UTxO`, and `ProtocolParameters` values — no manual CBOR handling required. A lower-level raw API is also available for advanced use cases.

The top-level entry point is `CardanoNode`, which provides two factory methods:

| Factory | Transport | Use case |
|---|---|---|
| `CardanoNode.connectToClient(config:)` | Unix socket (NtC) | Talking to a local `cardano-node` process |
| `CardanoNode.connectToNode(config:)` | TCP (NtN) | Connecting to a remote Cardano peer |

Both factory methods perform the Handshake negotiation automatically before returning a ready-to-use connection object.

---

## Quick Start

### Node-to-Client (local node)

Connect to a running `cardano-node` process via its Unix socket to get full block data, submit transactions, query ledger state, and inspect the mempool.

```swift
import SwiftCardanoNetwork

var config = CardanoNetworkConfiguration.mainnet
config.connection.socketPath = "/ipc/node.socket"

let connection = try await CardanoNode.connectToClient(config: config)
defer { await connection.close() }

// Stream full decoded blocks (requires SwiftCardanoCore)
for try await event in connection.followTyped() {
    switch event {
    case .rollForward(let block, let tip):
        print("Block txs=\(block.transactionBodies.count) tip=\(tip.blockNo)")
    case .rollBackward(let point, _):
        print("Rollback to \(point)")
    }
}
```

### Node-to-Node (remote peer)

Connect to a remote Cardano relay peer over TCP to stream block headers and participate in transaction propagation.

```swift
import SwiftCardanoNetwork

let connection = try await CardanoNode.connectToNode(config: .mainnet)
defer { await connection.close() }

// Stream decoded block headers (full bodies require BlockFetch)
for try await event in connection.chainSync.followTyped() {
    if case .rollForward(let block, let tip) = event {
        print("Block tip=\(tip.blockNo)")
    }
}
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

| Variable | Config field |
|---|---|
| `CARDANO_NETWORK_SOCKET_PATH` | `connection.socketPath` |
| `CARDANO_NETWORK_HOST` | `connection.host` |
| `CARDANO_NETWORK_PORT` | `connection.port` |
| `CARDANO_NETWORK_MAGIC` | `connection.networkMagic` |
| `CARDANO_NETWORK_CONNECT_TIMEOUT` | `connection.connectTimeoutSeconds` |
| `CARDANO_NETWORK_LOG_LEVEL` | `logging.level` |
| `CARDANO_NETWORK_METRICS_ENABLED` | `metrics.enabled` |

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

Streams chain events as an `AsyncThrowingStream<TypedChainEvent, Error>`. NtC delivers **full decoded blocks**; NtN delivers **decoded block headers** only.

```swift
// Follow from the current tip (no intersection point needed)
for try await event in connection.chainSync.followTyped() {
    if case .rollForward(let block, let tip) = event {
        print("Transactions: \(block.transactionBodies.count), tip: \(tip.blockNo)")
    }
}

// Follow from a known intersection point to avoid re-syncing
let knownPoint = Point.blockPoint(slot: 50_000_000, hash: knownHashBytes)
for try await event in connection.chainSync.followTyped(from: [knownPoint]) { ... }
```

`TypedChainEvent` cases:
- `.rollForward(Block, Tip)` — new decoded block or header available
- `.rollBackward(Point, Tip)` — chain rolled back; resync from `point`

The convenience method `connection.followTyped(from:)` is also available directly on `NodeToClientConnection`.

Breaking out of a `for try await` loop or cancelling the enclosing `Task` terminates the stream cleanly.

### BlockFetch (NtN only)

Downloads complete block bodies for a range of chain points. Use this after ChainSync delivers a header over an NtN connection.

```swift
let blocks = try await connection.blockFetch.fetch(
    from: .blockPoint(slot: 1_000_000, hash: startHash),
    to:   .blockPoint(slot: 1_001_000, hash: endHash)
)

for block in blocks {
    print("Block body: \(block.readableBytes) bytes raw CBOR")
}
```

`fetch(from:to:)` returns `[ByteBuffer]`, one raw CBOR buffer per block. Throws `BlockFetchError.emptyBatch` if the node has no blocks in the requested range.

### LocalTxSubmission (NtC only)

Submit a signed `Transaction` to a local node. Pass a fully-typed `Transaction` from `swift-cardano-core` — serialisation is handled automatically. The `era` parameter is a `SwiftCardanoCore.Era` enum value and defaults to `.conway`.

```swift
// Submit and get the TransactionId back
do {
    let txId = try await connection.submit(signedTx)
    print("Accepted: \(txId)")
} catch LocalTxSubmissionError.rejected(let rejection) {
    // rejection.era is a typed Era value, e.g. .conway, .babbage, etc.
    print("Rejected — era=\(rejection.era) reason=\(rejection.reasonCBOR.readableBytes) bytes")
}

// Or submit without capturing the ID
try await connection.txSubmission.submit(signedTx)

// Submit for an earlier era explicitly using the Era enum
try await connection.txSubmission.submit(signedTx, era: .babbage)
```

The `Era` enum covers all Cardano eras and maps to the wire tag used by the Ouroboros protocol:

| Era | Wire tag |
|---|---|
| `.byron` | 0 |
| `.shelley` | 1 |
| `.allegra` | 2 |
| `.mary` | 3 |
| `.alonzo` | 4 |
| `.babbage` | 5 |
| `.conway` | 6 |

Use `connection.submitChecked(_:)` (shorthand on `NodeToClientConnection`) to submit and return the `TransactionId` in one call.

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

// Governance state (Conway) — raw CBOR
let govState = try await connection.stateQuery.queryGovernanceState()
```

All convenience methods are available both via `connection.stateQuery.*` and as top-level shorthand on `NodeToClientConnection`. Each call acquires a ledger snapshot, runs the query, then releases the snapshot automatically.

### LocalTxMonitor (NtC only)

Inspect the node's local mempool — enumerate pending transactions as decoded `Transaction` values, check for a specific transaction, and read capacity metrics.

```swift
// Snapshot the entire mempool — returns decoded Transaction values
let (slotNo, txs) = try await connection.snapshotMempool()
print("Mempool at slot \(slotNo): \(txs.count) transaction(s)")
for tx in txs {
    print("  tx id: \(tx.id?.description ?? "unknown")")
}

// Check whether a specific transaction is pending
let txIdBytes: [UInt8] = ...  // 32-byte transaction ID
let present = try await connection.txMonitor.hasTx(txIdBytes)

// Read mempool capacity
let capacity = try await connection.txMonitor.capacity()
print("Capacity: \(capacity.capacityInBytes) bytes, \(capacity.numberOfTxs) txs")
```

`connection.snapshotMempool()` is a shorthand for `connection.txMonitor.snapshotTyped()` and both return `(slotNo: UInt64, txs: [Transaction])`.

### TxSubmission2 (NtN only)

Pull-based transaction propagation with a remote peer. Implement the `TxSubmissionProvider` protocol to serve transactions from your mempool when the remote peer requests them.

```swift
try await connection.txSubmission2.run(provider: myMempool)
```

---

## Connection Lifecycle

Both `NodeToClientConnection` and `NodeToNodeConnection` have a `close()` method that shuts down the connection gracefully. For NtN connections this also cancels the background KeepAlive probe loop.

```swift
let connection = try await CardanoNode.connectToClient(config: config)
defer { await connection.close() }
// ... use connection ...
```

`close()` is safe to call multiple times.

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

### Metrics

All mini-protocols emit [swift-metrics](https://github.com/apple/swift-metrics)-compatible metrics. Bootstrap a metrics backend (e.g. `prometheus-client-swift`) in your app startup:

| Metric | Type | Description |
|---|---|---|
| `cardano_network_bytes_received_total` | Counter | Total bytes received |
| `cardano_network_bytes_sent_total` | Counter | Total bytes sent |
| `cardano_network_connections_total` | Counter | Total connections opened |
| `cardano_network_connections_active` | Gauge | Currently open connections |
| `cardano_network_handshake_total` | Counter | Handshake completions |
| `cardano_network_handshake_duration_seconds` | Timer | Handshake latency |
| `cardano_network_blocks_received_total` | Counter | Blocks received via ChainSync |
| `cardano_network_rollbacks_total` | Counter | Chain rollback events |
| `cardano_network_tx_submissions_total` | Counter | Tx submission attempts (`result=accepted\|rejected`) |
| `cardano_network_tx_submission_duration_seconds` | Timer | Tx submission latency |
| `cardano_network_query_duration_seconds` | Timer | LocalStateQuery latency |
| `cardano_network_block_fetch_duration_seconds` | Timer | BlockFetch range download latency |
| `cardano_network_keepalive_rtt_seconds` | Timer | KeepAlive round-trip time |
| `cardano_network_mempool_tx_count` | Gauge | Transactions in mempool snapshot |
| `cardano_network_mempool_capacity_bytes` | Gauge | Mempool capacity in bytes |
| `cardano_network_chain_tip_slot` | Gauge | Chain tip slot number |
| `cardano_network_chain_tip_block` | Gauge | Chain tip block number |
| `cardano_network_sdu_decode_errors_total` | Counter | Mux frame decode failures |
| `cardano_network_agency_violations_total` | Counter | Protocol agency violations |

---

## Architecture

```
CardanoNode (factory)
├── connectToClient()  →  NodeToClientConnection
│       ├── chainSync       (ChainSyncClient — full blocks)
│       ├── txSubmission    (LocalTxSubmissionClient)
│       ├── stateQuery      (LocalStateQueryClient)
│       └── txMonitor       (LocalTxMonitorClient)
│
└── connectToNode()    →  NodeToNodeConnection
        ├── chainSync       (ChainSyncClient — headers)
        ├── blockFetch      (BlockFetchClient)
        └── txSubmission2   (TxSubmission2Client)
```

**Transport layer** (`Transport/`) — `UnixSocketTransport` and `TCPTransport` wrap SwiftNIO channels and produce a `(Channel, DemuxHandler)` tuple.

**Mux layer** (`Mux/`) — `MuxFrameDecoder` and `MuxFrameEncoder` implement the Ouroboros SDU framing. `DemuxHandler` routes inbound frames to the correct mini-protocol stream by protocol ID.

**Protocol Driver** (`Driver/`) — `ProtocolDriver` wraps a channel and a state machine, sending and receiving type-safe messages. Each client creates a fresh driver per operation.

**Mini-protocols** (`Protocols/`) — Each sub-folder contains:
- `*Messages.swift` — CBOR-tagged message types
- `*StateMachine.swift` — Agency-based state machine
- `*Codec.swift` — CBOR encode/decode
- `*Client.swift` — Public async API

---

## Testing

Run the full test suite (440+ tests):

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
