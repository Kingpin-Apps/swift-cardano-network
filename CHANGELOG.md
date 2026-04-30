## 1.0.6 (2026-04-30)

### Fix

- update documentation to reflect changes in EraBlock and EraHeader usage

## 1.0.5 (2026-04-30)

### Fix

- Add unit tests for CurrentEpochState, DebugLedgerState, and ChainDepState models

## 1.0.4 (2026-04-28)

### Fix

- check for node before running
- require swift-log >= 1.7.0 for LogEvent, FileLogHandler and SystemLogHandler

## 1.0.3 (2026-04-27)

### Fix

- add OutboundGovernor and PeerSharing

## 1.0.2 (2026-04-26)

### Fix

- add documentation

## 1.0.1 (2026-04-26)

### Fix

- fix tests

## 1.0.0 (2026-04-26)

### Feat

- **config**: bump default ntcVersions to NodeToClientVersion.allKnown
- **mock**: add maxNtcVersion to MockNodeConfig and gate handshake reply
- **lsq**: add new queries gated v20/v21/v23
- **lsq**: version-aware encoding for bigLedgerPeerSnapshot SRV form
- **lsq**: version-aware encoding for stakeDistribution and poolDistr
- **lsq**: convert LedgerQuery factories to version-aware functions
- **lsq**: introduce NtcQueryGate with upstream version gating table
- **handshake**: add NodeToClientVersion v22/v23 constants and allKnown helper

### Fix

- improve tx submission error handling
- **lsq**: decode v2 PoolDistr returned by GetPoolDistr2 (NtCv21+)
- **lsq**: decode v2 BigLedgerPeerSnapshot returned by NtCv23 nodes
- **lsq**: handle Maybe-wrapped params in FuturePParams decoder
- **handshake**: emit proposeVersions map keys in CBOR canonical (ascending) order
- Enhance LocalTxMonitor protocol with era-aware transaction handling and typed snapshots

### Refactor

- **lsq**: plumb negotiatedVersion into LocalStateQueryClient

## 0.1.3 (2026-04-25)

### Fix

- Refactor LocalStateQueryClient and related codecs for improved CBOR handling

## 0.1.2 (2026-04-23)

### Fix

- Refactor encoding/decoding in tests to use mutable buffers

## 0.1.1 (2026-04-19)

### Refactor

- update connection methods to use scoped resource management
