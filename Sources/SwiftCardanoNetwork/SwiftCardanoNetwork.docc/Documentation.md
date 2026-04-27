# ``SwiftCardanoNetwork``

A complete Swift async/await client for the Cardano [Ouroboros](https://iohk.io/en/research/library/papers/ouroboros-a-provably-secure-proof-of-stake-blockchain-protocol/) networking stack, supporting both Node-to-Client and Node-to-Node connectivity.

## Overview

SwiftCardanoNetwork implements the full Ouroboros mini-protocol suite over a multiplexed TCP or Unix domain socket connection. All mini-protocols expose a **typed API** backed by [SwiftCardanoCore](https://github.com/Kingpin-Apps/swift-cardano-core) that works with fully-decoded `Block`, `Transaction`, `UTxO`, and `ProtocolParameters` values — no manual CBOR handling required.

Two transport modes are available:

- **Node-to-Client (NtC)** — connects to a local `cardano-node` process via Unix domain socket. Provides full decoded blocks via ChainSync, transaction submission, ledger state queries, and mempool inspection.
- **Node-to-Node (NtN)** — connects to a remote Cardano relay peer over TCP. Provides block header streaming via ChainSync, full block bodies via BlockFetch, and peer-based transaction propagation via TxSubmission2.

The top-level entry point is ``CardanoNode``, which provides scoped factory methods that close the connection automatically, or manual-lifetime variants when you need to control the connection lifecycle yourself.

```swift
import SwiftCardanoNetwork

// Connect to a local node and stream decoded blocks
var config = CardanoNetworkConfiguration.mainnet
config.connection.socketPath = "/ipc/node.socket"

try await CardanoNode.withClient(config: config) { connection in
    for try await event in connection.follow(from: []) {
        if case .rollForward(let block, let tip) = event {
            print("Block txs=\(block.transactionBodies.count) tip=\(tip.blockNo)")
        }
    }
}
```

### Mini-Protocols

| Protocol | Transport | Client | Purpose |
|---|---|---|---|
| ChainSync | NtC + NtN | ``ChainSyncClient`` | Stream full blocks (NtC) or block headers (NtN) |
| BlockFetch | NtN | ``BlockFetchClient`` | Download full block bodies for a point range |
| LocalTxSubmission | NtC | ``LocalTxSubmissionClient`` | Submit signed transactions |
| LocalStateQuery | NtC | ``LocalStateQueryClient`` | Query UTxOs, protocol params, governance state, and more |
| LocalTxMonitor | NtC | ``LocalTxMonitorClient`` | Inspect the node's local mempool |
| TxSubmission2 | NtN | ``TxSubmission2Client`` | Pull-based transaction propagation with a remote peer |
| Handshake | NtC + NtN | ``HandshakeClient`` | Version negotiation (automatic on connect) |
| KeepAlive | NtN | ``KeepAliveHandler`` | Background probe loop (automatic on NtN connect) |
| Ping-Pong | Dummy | ``PingPongClient`` | Liveness check for testing |
| Request-Response | Dummy | ``ReqRespClient`` | Polymorphic single-shot protocol for testing |

### Architecture

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

**Transport layer** — `UnixSocketTransport` and `TCPTransport` wrap SwiftNIO channels.

**Mux layer** — `MuxFrameDecoder` and `MuxFrameEncoder` implement the Ouroboros SDU framing. ``DemuxHandler`` routes inbound frames to the correct mini-protocol stream by protocol ID.

**Protocol Driver** — ``ProtocolDriver`` wraps a channel and an agency-based state machine, enforcing the send/receive rules of each mini-protocol.

## Topics

### Articles

- <doc:OutboundGovernor>

### Entry Points

- ``CardanoNode``
- ``NodeToClientConnection``
- ``NodeToNodeConnection``
- ``OutboundGovernor``

### Configuration

- ``CardanoNetworkConfiguration``
- ``ConnectionConfig``
- ``LoggingConfig``
- ``MetricsConfig``
- ``ProtocolConfig``

### Chain Synchronisation

- ``ChainSyncClient``
- ``ChainEvent``
- ``ChainSyncError``

### Block Download

- ``BlockFetchClient``
- ``BlockFetchError``

### Transaction Submission

- ``LocalTxSubmissionClient``
- ``LocalTxSubmissionError``
- ``RawTransaction``
- ``TxRejection``

### Ledger State Queries

- ``LocalStateQueryClient``
- ``LocalStateQueryError``
- ``LedgerQuery``
- ``RawQuery``
- ``RawResult``
- ``NtcQueryGate``
- ``AcquirePoint``
- ``AcquireFailure``

### Mempool Monitoring

- ``LocalTxMonitorClient``
- ``LocalTxMonitorError``
- ``MempoolTx``
- ``MempoolCapacity``

### Node-to-Node Transaction Propagation

- ``TxSubmission2Client``
- ``TxSubmissionProvider``

### Version Negotiation

- ``HandshakeClient``
- ``HandshakeError``
- ``HandshakeVersionData``
- ``NegotiatedVersion``
- ``NodeToNodeVersion``
- ``NodeToClientVersion``
- ``RefuseReason``

### Keep-Alive

- ``KeepAliveHandler``
- ``KeepAliveError``

### Dummy Protocols

- ``PingPongClient``
- ``PingPongError``
- ``ReqRespClient``
- ``ReqRespCodec``
- ``ReqRespError``

### Protocol Driver

- ``ProtocolDriver``
- ``ProtocolCodec``
- ``ProtocolState``
- ``Agency``
- ``ProtocolError``

### Multiplexer

- ``DemuxHandler``
- ``MuxError``

### Ledger State Models

- ``AccountState``
- ``ActiveProposals``
- ``CommitteeMembersState``
- ``DRepState``
- ``DRepStakeDistribution``
- ``FilteredDelegationsAndRewards``
- ``GovernanceState``
- ``LedgerConstitution``
- ``NonMyopicMemberRewards``
- ``PoolDistr``
- ``PoolState``
- ``RatifyState``
- ``RewardInfoPools``
- ``RewardProvenance``
- ``SPOStakeDistribution``
- ``StakeDelegDeposits``
- ``StakePoolParams``
- ``StakePools``
- ``StakeSnapshots``
- ``VoteDelegatees``
