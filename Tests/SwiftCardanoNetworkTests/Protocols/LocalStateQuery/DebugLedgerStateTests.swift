import Foundation
import NIOCore
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - DebugLedgerState model unit tests

@Suite("DebugLedgerState") struct DebugLedgerStateTests {

    // Build minimal DebugLedgerState CBOR for testing.
    //
    // Wire layout: array(6) [epochNo, bprev, bcurr, epochState, rewUpd, poolDistr]
    //
    // epochNo    = uint(10)   → 0x0A
    // bprev      = map(0)    → 0xA0
    // bcurr      = map(0)    → 0xA0
    // epochState = array(4) [accountState, ledgerState, snapshots, nonMyopic]
    //   accountState = array(2) [uint(1), uint(2)]  → 0x82 0x01 0x02
    //   ledgerState  = array(2) [utxoState, certState]
    //     utxoState = array(5) [map(0), uint(0), uint(0), array(0), array(0)]
    //               → 0x85 0xA0 0x00 0x00 0x80 0x80
    //     certState = array(0) → 0x80
    //     → 0x82 0x85 0xA0 0x00 0x00 0x80 0x80 0x80
    //   snapshots    = array(4) [array(0), array(0), array(0), uint(0)]
    //               → 0x84 0x80 0x80 0x80 0x00
    //   nonMyopic    = array(2) [map(0), uint(0)] → 0x82 0xA0 0x00
    // rewUpd     = array(0)  → 0x80
    // poolDistr  = map(0)    → 0xA0
    private static let minimalCBOR: [UInt8] = [
        0x86,                                               // array(6)
        0x0A,                                               // uint(10)   — epochNo
        0xA0,                                               // map(0)     — blocksMadePrev
        0xA0,                                               // map(0)     — blocksMadeCurr
        0x84,                                               // array(4)   — epochState
          0x82, 0x01, 0x02,                                 //   accountState [1, 2]
          0x82, 0x85, 0xA0, 0x00, 0x00, 0x80, 0x80, 0x80,  //   ledgerState
          0x84, 0x80, 0x80, 0x80, 0x00,                    //   snapshots
          0x82, 0xA0, 0x00,                                 //   nonMyopic
        0x80,                                               // array(0)   — rawPulsingRewUpdate
        0xA0,                                               // map(0)     — poolDistribution
    ]

    @Test("decodes epochNo correctly")
    func decodesEpochNo() throws {
        let state = try DebugLedgerState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.epochNo == 10)
    }

    @Test("decodes empty blocksMadePrev and blocksMadeCurr maps")
    func decodesEmptyBlocksMade() throws {
        let state = try DebugLedgerState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.blocksMadePrev.isEmpty)
        #expect(state.blocksMadeCurr.isEmpty)
    }

    @Test("decodes non-empty blocksMade maps")
    func decodesNonEmptyBlocksMade() throws {
        let key = Data(repeating: 0x00, count: 28)
        let bprev = Primitive.dict([.bytes(key): .uint(5)])
        let bcurr = Primitive.dict([.bytes(key): .uint(7)])
        let epochState = Primitive.list([
            .list([.uint(0), .uint(0)]),
            .list([
                .list([.dict([:]), .uint(0), .uint(0), .list([]), .list([])]),
                .list([]),
            ]),
            .list([.list([]), .list([]), .list([]), .uint(0)]),
            .list([.dict([:]), .uint(0)]),
        ])
        let primitive = Primitive.list([
            .uint(1), bprev, bcurr, epochState,
            .list([]),  // pulsingRewUpdate — StrictMaybe Nothing
            .dict([:]), // poolDistribution
        ])
        let state = try DebugLedgerState(from: primitive)
        #expect(state.blocksMadePrev[key] == 5)
        #expect(state.blocksMadeCurr[key] == 7)
    }

    @Test("embeds epochState with correct accountState")
    func embedsCurrentEpochState() throws {
        let state = try DebugLedgerState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.epochState.accountState.treasury == 1)
        #expect(state.epochState.accountState.reserves == 2)
    }

    @Test("pulsingRewUpdate is nil for empty-array StrictMaybe Nothing")
    func pulsingRewUpdateIsNilForNothing() throws {
        let state = try DebugLedgerState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.pulsingRewUpdate == nil)
    }

    @Test("exposes poolDistribution entries count")
    func exposesPoolDistribution() throws {
        let state = try DebugLedgerState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.poolDistribution.entries.isEmpty)
        #expect(state.poolDistribution.totalStake == nil)
    }

    @Test("opaque fields preserved through toPrimitive round-trip")
    func roundTripsOpaqueFields() throws {
        let state = try DebugLedgerState.fromCBOR(data: Data(Self.minimalCBOR))
        let roundTripped = try DebugLedgerState(from: try state.toPrimitive())
        #expect(state == roundTripped)
    }

    @Test("init(from:) throws when array has fewer than 6 elements")
    func throwsOnShortArray() {
        #expect(throws: (any Error).self) {
            _ = try DebugLedgerState(from: .list([.uint(1), .dict([:]), .dict([:])]))
        }
    }

    @Test("init(from:) throws when blocksMade is not a map")
    func throwsWhenBlocksMadeIsNotMap() {
        let epochState = Primitive.list([
            .list([.uint(0), .uint(0)]),
            .list([
                .list([.dict([:]), .uint(0), .uint(0), .list([]), .list([])]),
                .list([]),
            ]),
            .list([.list([]), .list([]), .list([]), .uint(0)]),
            .list([.dict([:]), .uint(0)]),
        ])
        #expect(throws: (any Error).self) {
            _ = try DebugLedgerState(from: .list([
                .uint(1),
                .uint(0),   // wrong type — not a map
                .dict([:]),
                epochState,
                .list([]),
                .dict([:]),
            ]))
        }
    }
}
