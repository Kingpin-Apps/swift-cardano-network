import Foundation
import NIOCore
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - ChainDepState model unit tests

@Suite("ChainDepState") struct ChainDepStateTests {

    // Minimal ChainDepState CBOR (empty ocertCounters, Origin lastSlot):
    //
    // array(7)  →  0x87
    //   array(0)  →  0x80   lastSlot = Origin
    //   array(0)  →  0x80   hashesBefore  (opaque)
    //   array(0)  →  0x80   evolvingNonce (opaque)
    //   array(0)  →  0x80   candidateNonce (opaque)
    //   array(0)  →  0x80   epochNonce    (opaque)
    //   array(0)  →  0x80   labNonce      (opaque)
    //   map(0)    →  0xA0   ocertCounters = {}
    private static let minimalCBOR: [UInt8] = [
        0x87,
        0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
        0xA0,
    ]

    @Test("decodes empty operationalCertCounters map")
    func decodesEmptyCounters() throws {
        let state = try ChainDepState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.operationalCertCounters.isEmpty)
    }

    @Test("lastSlot is nil when encoded as Origin (empty list)")
    func lastSlotNilForOrigin() throws {
        let state = try ChainDepState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.lastSlot == nil)
    }

    @Test("decodes operationalCertCounters with one entry")
    func decodesOCertCounters() throws {
        let poolHash = Data(repeating: 0xAB, count: 28)
        let counters = Primitive.dict([.bytes(poolHash): .uint(3)])
        let primitive = Primitive.list([
            .list([]),          // lastSlot = Origin
            .list([]),          // hashesBefore
            .list([]),          // evolvingNonce
            .list([]),          // candidateNonce
            .list([]),          // epochNonce
            .list([]),          // labNonce
            counters,           // ocertCounters
        ])
        let state = try ChainDepState(from: primitive)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state.operationalCertCounters[poolOp] == 3)
        #expect(state.operationalCertCounters.count == 1)
    }

    @Test("decodes lastSlot when encoded as At(slot)")
    func lastSlotDecodedAtSlot() throws {
        let primitive = Primitive.list([
            .list([.uint(12345)]),  // lastSlot = At(12345)
            .list([]), .list([]), .list([]), .list([]), .list([]),
            .dict([:]),
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.lastSlot == 12345)
    }

    @Test("toPrimitive round-trip preserves counter values")
    func roundTripsCounters() throws {
        let poolHash = Data(repeating: 0x01, count: 28)
        let primitive = Primitive.list([
            .list([]),
            .list([]), .list([]), .list([]), .list([]), .list([]),
            .dict([.bytes(poolHash): .uint(7)]),
        ])
        let state = try ChainDepState(from: primitive)
        let roundTripped = try ChainDepState(from: try state.toPrimitive())
        let poolOp = try PoolOperator(from: poolHash)
        #expect(roundTripped.operationalCertCounters[poolOp] == 7)
    }

    @Test("init(from:) throws when ocertCounters key is not bytes")
    func throwsOnNonBytesKey() {
        let badMap = Primitive.dict([.uint(0): .uint(1)])
        let primitive = Primitive.list([
            .list([]),
            .list([]), .list([]), .list([]), .list([]), .list([]),
            badMap,
        ])
        #expect(throws: (any Error).self) {
            _ = try ChainDepState(from: primitive)
        }
    }

    @Test("init(from:) throws when ocertCounters value is not uint")
    func throwsOnNonUIntValue() {
        let key = Data(repeating: 0x00, count: 28)
        let badMap = Primitive.dict([.bytes(key): .bytes(Data([0x01]))])
        let primitive = Primitive.list([
            .list([]),
            .list([]), .list([]), .list([]), .list([]), .list([]),
            badMap,
        ])
        #expect(throws: (any Error).self) {
            _ = try ChainDepState(from: primitive)
        }
    }

    @Test("init(from:) throws when ocertCounters is not a map")
    func throwsWhenCountersNotMap() {
        let primitive = Primitive.list([
            .list([]),
            .list([]), .list([]), .list([]), .list([]), .list([]),
            .uint(0),   // wrong type
        ])
        #expect(throws: (any Error).self) {
            _ = try ChainDepState(from: primitive)
        }
    }

    @Test("init(from:) throws when array has fewer than 7 elements")
    func throwsOnShortArray() {
        #expect(throws: (any Error).self) {
            _ = try ChainDepState(from: .list([.list([]), .list([])]))
        }
    }

    // MARK: - Wire encoding (live-node format)

    @Test("decodes lastSlot with live-node [1, slot] At encoding")
    func lastSlotDecodedAtSlotWireFormat() throws {
        // Live nodes encode At(slot) as [1, slot], not [slot].
        let primitive = Primitive.list([
            .list([.uint(1), .uint(99999)]),  // At(99999) wire form
            .list([]), .list([]), .list([]), .list([]), .list([]),
            .dict([:]),
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.lastSlot == 99999)
    }

    @Test("decodes lastSlot as nil with live-node [0] Origin encoding")
    func lastSlotNilForOriginWireFormat() throws {
        // Live nodes encode Origin as [0], not [].
        let primitive = Primitive.list([
            .list([.uint(0)]),  // Origin wire form
            .list([]), .list([]), .list([]), .list([]), .list([]),
            .dict([:]),
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.lastSlot == nil)
    }

    @Test("unwraps HardFork era-constructor wrapper [0, PraosState]")
    func unwrapsHardForkWrapper() throws {
        // Live nodes wrap PraosState in [0, actualState].
        let poolHash = Data(repeating: 0xCC, count: 28)
        let inner = Primitive.list([
            .list([.uint(1), .uint(111_000_000)]),   // At(111000000)
            .list([]), .list([]), .list([]), .list([]), .list([]),
            .dict([.bytes(poolHash): .uint(5)]),
        ])
        let wrapped = Primitive.list([.uint(0), inner])
        let state = try ChainDepState(from: wrapped)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state.lastSlot == 111_000_000)
        #expect(state.operationalCertCounters[poolOp] == 5)
    }

    @Test("decodes 8-element PraosState (six nonce slots, ocertCounters at index 6)")
    func decodes8ElementPraosState() throws {
        // SERIALISE-reference layout: ocertCounters last, six nonces in front.
        let poolHash = Data(repeating: 0xDD, count: 28)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(111_000_000)]),   // At(111000000) — lastSlot
            .list([]), .list([]), .list([]),          // nonces 0..2
            .list([]), .list([]), .list([]),          // nonces 3..5 (incl. previousEpochNonce)
            .dict([.bytes(poolHash): .uint(9)]),     // ocertCounters at index 7
        ])
        let state = try ChainDepState(from: primitive)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state.lastSlot == 111_000_000)
        #expect(state.operationalCertCounters[poolOp] == 9)
        #expect(state.rawExtraFields.isEmpty)
    }

    // MARK: - Nonce decoding

    @Test("decodes NeutralNonce (CBOR null) as nil for all five nonce fields")
    func decodesNeutralNonces() throws {
        let primitive = Primitive.list([
            .list([]),                  // lastSlot = Origin
            .null,                      // evolvingNonce = NeutralNonce
            .null,                      // candidateNonce
            .null,                      // epochNonce
            .null,                      // labNonce
            .null,                      // lastEpochBlockNonce
            .dict([:]),                 // ocertCounters (empty)
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.evolvingNonce == nil)
        #expect(state.candidateNonce == nil)
        #expect(state.epochNonce == nil)
        #expect(state.labNonce == nil)
        #expect(state.lastEpochBlockNonce == nil)
    }

    @Test("decodes real nonce bytes (bytes-32) into all six named nonce fields")
    func decodesNonceBytes() throws {
        let nonce0 = Data(repeating: 0xAA, count: 32)
        let nonce1 = Data(repeating: 0xBB, count: 32)
        let nonce2 = Data(repeating: 0xCC, count: 32)
        let nonce3 = Data(repeating: 0xDD, count: 32)
        let nonce4 = Data(repeating: 0xEE, count: 32)
        let nonce5 = Data(repeating: 0xFA, count: 32)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(500_000)]),  // lastSlot = At(500000)
            .bytes(nonce0),                     // evolvingNonce
            .bytes(nonce1),                     // candidateNonce
            .bytes(nonce2),                     // epochNonce
            .bytes(nonce3),                     // previousEpochNonce
            .bytes(nonce4),                     // labNonce
            .bytes(nonce5),                     // lastEpochBlockNonce
            .dict([:]),                          // ocertCounters at index 7
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.evolvingNonce == nonce0)
        #expect(state.candidateNonce == nonce1)
        #expect(state.epochNonce == nonce2)
        #expect(state.previousEpochNonce == nonce3)
        #expect(state.labNonce == nonce4)
        #expect(state.lastEpochBlockNonce == nonce5)
        #expect(state.rawExtraFields.isEmpty)
    }

    @Test("nonce round-trip preserves all six named nonces")
    func roundTripsNonces() throws {
        let nonce = Data(repeating: 0x42, count: 32)
        let poolHash = Data(repeating: 0x01, count: 28)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(1_000)]),
            .bytes(nonce), .null, .bytes(nonce),       // evolving, candidate, epoch
            .null, .bytes(nonce), .null,               // previousEpoch, lab, lastEpochBlock
            .dict([.bytes(poolHash): .uint(2)]),
        ])
        let state = try ChainDepState(from: primitive)
        let state2 = try ChainDepState(from: try state.toPrimitive())
        #expect(state2.evolvingNonce == nonce)
        #expect(state2.candidateNonce == nil)
        #expect(state2.epochNonce == nonce)
        #expect(state2.previousEpochNonce == nil)
        #expect(state2.labNonce == nonce)
        #expect(state2.lastEpochBlockNonce == nil)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state2.operationalCertCounters[poolOp] == 2)
    }

    @Test("nonces decode correctly when ocertCounters is at live-node index 1")
    func decodesNoncesWithCountersAtIndex1() throws {
        // Live Conway nodes put ocertCounters at index 1 (not last).
        let poolHash = Data(repeating: 0x55, count: 28)
        let nonce = Data(repeating: 0xFF, count: 32)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(110_000_000)]),
            .dict([.bytes(poolHash): .uint(7)]),    // ocertCounters at index 1
            .bytes(nonce),                           // evolvingNonce
            .null,                                   // candidateNonce
            .null,                                   // epochNonce
            .null,                                   // previousEpochNonce
            .null,                                   // labNonce
            .null,                                   // lastEpochBlockNonce
        ])
        let state = try ChainDepState(from: primitive)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state.lastSlot == 110_000_000)
        #expect(state.operationalCertCounters[poolOp] == 7)
        #expect(state.evolvingNonce == nonce)
        #expect(state.candidateNonce == nil)
        #expect(state.previousEpochNonce == nil)
        #expect(state.rawExtraFields.isEmpty)
    }

    // MARK: - Live wire-format Nonce encoding (cardano-ledger EncCBOR Nonce)

    @Test("decodes NeutralNonce in live wire form ([0])")
    func decodesNeutralNonceLiveWireForm() throws {
        // cardano-ledger encodes NeutralNonce as [0] (listLen 1, word 0),
        // not as CBOR null.
        let primitive = Primitive.list([
            .list([.uint(0)]),                     // lastSlot = Origin
            .dict([:]),                             // ocertCounters at live index 1
            .list([.uint(0)]),                     // evolvingNonce       = NeutralNonce
            .list([.uint(0)]),                     // candidateNonce
            .list([.uint(0)]),                     // epochNonce
            .list([.uint(0)]),                     // previousEpochNonce
            .list([.uint(0)]),                     // labNonce
            .list([.uint(0)]),                     // lastEpochBlockNonce
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.evolvingNonce == nil)
        #expect(state.candidateNonce == nil)
        #expect(state.epochNonce == nil)
        #expect(state.previousEpochNonce == nil)
        #expect(state.labNonce == nil)
        #expect(state.lastEpochBlockNonce == nil)
    }

    @Test("decodes Nonce h in live wire form ([1, bytes32]) into all six named slots")
    func decodesNonceHashLiveWireForm() throws {
        // cardano-ledger encodes Nonce h as [1, h] (listLen 2, word 1, 32-byte hash).
        // Field order matches `Serialise PraosState` from cardano-protocol-tpraos.
        let nonce0 = Data(repeating: 0xAA, count: 32)
        let nonce1 = Data(repeating: 0xBB, count: 32)
        let nonce2 = Data(repeating: 0xCC, count: 32)
        let nonce3 = Data(repeating: 0xDD, count: 32)
        let nonce4 = Data(repeating: 0xEE, count: 32)
        let nonce5 = Data(repeating: 0xFA, count: 32)
        let poolHash = Data(repeating: 0x77, count: 28)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(110_926_685)]),       // lastSlot
            .dict([.bytes(poolHash): .uint(4)]),         // ocertCounters at live index 1
            .list([.uint(1), .bytes(nonce0)]),           // evolvingNonce
            .list([.uint(1), .bytes(nonce1)]),           // candidateNonce
            .list([.uint(1), .bytes(nonce2)]),           // epochNonce
            .list([.uint(1), .bytes(nonce3)]),           // previousEpochNonce
            .list([.uint(1), .bytes(nonce4)]),           // labNonce
            .list([.uint(1), .bytes(nonce5)]),           // lastEpochBlockNonce
        ])
        let state = try ChainDepState(from: primitive)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state.lastSlot == 110_926_685)
        #expect(state.operationalCertCounters[poolOp] == 4)
        #expect(state.evolvingNonce == nonce0)
        #expect(state.candidateNonce == nonce1)
        #expect(state.epochNonce == nonce2)
        #expect(state.previousEpochNonce == nonce3)
        #expect(state.labNonce == nonce4)
        #expect(state.lastEpochBlockNonce == nonce5)
        #expect(state.rawExtraFields.isEmpty)
    }

    @Test("previousEpochNonce sits at index 3 of the post-counters tail (regression)")
    func previousEpochNonceFieldOrder() throws {
        // Earlier versions of this decoder mislabelled the 6th wire-position
        // field as `labNonce`, the 7th as `lastEpochBlockNonce`, and dropped
        // the real `lastEpochBlockNonce` into `rawExtraFields`. This pins the
        // ordering against the cardano-protocol-tpraos source of truth.
        let prevEpoch = Data(repeating: 0x06, count: 32)
        let lab       = Data(repeating: 0x07, count: 32)
        let lastEpoch = Data(repeating: 0x08, count: 32)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(110_000_000)]),
            .dict([:]),                                  // ocertCounters at index 1
            .list([.uint(0)]),                           // evolvingNonce       = neutral
            .list([.uint(0)]),                           // candidateNonce      = neutral
            .list([.uint(0)]),                           // epochNonce          = neutral
            .list([.uint(1), .bytes(prevEpoch)]),        // previousEpochNonce
            .list([.uint(1), .bytes(lab)]),              // labNonce
            .list([.uint(1), .bytes(lastEpoch)]),        // lastEpochBlockNonce
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.previousEpochNonce  == prevEpoch)
        #expect(state.labNonce            == lab)
        #expect(state.lastEpochBlockNonce == lastEpoch)
        #expect(state.rawExtraFields.isEmpty)
    }

    @Test("Nonce round-trip uses live wire form ([0] / [1, h])")
    func roundTripsNoncesInLiveWireForm() throws {
        // Decode via the legacy bytes(32)/null forms, re-encode through
        // toPrimitive(), and confirm the output uses the live wire form
        // (ocertCounters at index 1, six nonces in PraosState field order).
        let nonce = Data(repeating: 0x42, count: 32)
        let poolHash = Data(repeating: 0x01, count: 28)
        let input = Primitive.list([
            .list([.uint(1), .uint(1_000)]),
            .bytes(nonce), .null, .bytes(nonce),         // evolving / candidate / epoch
            .null, .bytes(nonce), .null,                  // previousEpoch / lab / lastEpochBlock
            .dict([.bytes(poolHash): .uint(2)]),
        ])
        let state = try ChainDepState(from: input)
        let encoded = try state.toPrimitive()

        guard case .list(let elems) = encoded, elems.count == 8 else {
            Issue.record("encoded primitive must be an 8-element list (live Conway shape)"); return
        }
        // Index 1 is ocertCounters in the live shape.
        switch elems[1] {
        case .dict, .orderedDict, .frozenDict: break
        default: Issue.record("ocertCounters should sit at index 1 after round-trip"); return
        }
        // Index 2 is evolvingNonce — was non-nil → expect [1, bytes(nonce)].
        guard case .list(let evolving) = elems[2],
              evolving.count == 2,
              case .uint(1) = evolving[0],
              case .bytes(let evolvingBytes) = evolving[1]
        else {
            Issue.record("evolvingNonce should be encoded as [1, bytes32]"); return
        }
        #expect(evolvingBytes == nonce)
        // Index 3 is candidateNonce — was nil → expect [0].
        guard case .list(let candidate) = elems[3],
              candidate.count == 1,
              case .uint(0) = candidate[0]
        else {
            Issue.record("candidateNonce should be encoded as [0]"); return
        }

        // Full round-trip preserves values.
        let state2 = try ChainDepState(from: encoded)
        #expect(state2.evolvingNonce       == nonce)
        #expect(state2.candidateNonce      == nil)
        #expect(state2.epochNonce          == nonce)
        #expect(state2.previousEpochNonce  == nil)
        #expect(state2.labNonce            == nonce)
        #expect(state2.lastEpochBlockNonce == nil)
        let poolOp = try PoolOperator(from: poolHash)
        #expect(state2.operationalCertCounters[poolOp] == 2)
    }

    @Test("legacy null/bytes(32) Nonce forms are still decoded for backwards compat")
    func decodesLegacyNonceForms() throws {
        // The unit-test corpus historically used `null` / `bytes(32)` for nonces.
        // Those must keep working alongside the new live wire form.
        let nonce = Data(repeating: 0x33, count: 32)
        let primitive = Primitive.list([
            .list([.uint(1), .uint(42)]),
            .dict([:]),
            .bytes(nonce),                          // legacy: bytes(32)  → evolvingNonce
            .null,                                  // legacy: null       → candidateNonce
            .list([.uint(1), .bytes(nonce)]),       // live:   [1, h]    → epochNonce
            .list([.uint(0)]),                      // live:   [0]       → previousEpochNonce
            .null,                                  // legacy: null       → labNonce
            .bytes(nonce),                          // legacy: bytes(32)  → lastEpochBlockNonce
        ])
        let state = try ChainDepState(from: primitive)
        #expect(state.evolvingNonce       == nonce)
        #expect(state.candidateNonce      == nil)
        #expect(state.epochNonce          == nonce)
        #expect(state.previousEpochNonce  == nil)
        #expect(state.labNonce            == nil)
        #expect(state.lastEpochBlockNonce == nonce)
    }
}
