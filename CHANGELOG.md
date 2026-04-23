## Unreleased

### Feat

- add Ping-Pong dummy mini-protocol (§3.5.1 of the network spec)
- add generic Request-Response dummy mini-protocol (§3.5.2 of the network spec)
- reserve dummy protocol IDs `pingPong = 0x7FFE` and `reqResp = 0x7FFD`
- extend `MockCardanoNode` with pingPong and reqResp server handlers for tests
- expose `pingPong` client property and `reqResp(codec:)` / `requestResponse(_:codec:)` shortcuts on both `NodeToClientConnection` and `NodeToNodeConnection`
- add missing NtN shortcuts on `NodeToNodeConnection`: `fetch(from:to:)` and `serveTransactions(provider:)`
- add missing NtC mempool shortcuts on `NodeToClientConnection`: `hasTx(_:)`, `mempoolSizes()`, `mempoolMeasures()`
- add handshake-less factories `CardanoNode.connectToClientWithoutHandshake`, `connectToNodeWithoutHandshake`, and their scoped `withClientWithoutHandshake` / `withNodeWithoutHandshake` variants for dummy-protocol sessions
- `NodeToNodeConnection` gains a `startKeepAlive` init flag (default `true`) so dummy-only connections can skip the KeepAlive probe loop

## 0.1.1 (2026-04-19)

### Refactor

- update connection methods to use scoped resource management
