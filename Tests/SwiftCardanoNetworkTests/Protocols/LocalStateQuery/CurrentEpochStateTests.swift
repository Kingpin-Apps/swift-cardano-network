import Foundation
import NIOCore
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - CurrentEpochState model unit tests

@Suite("CurrentEpochState") struct CurrentEpochStateTests {

    // CBOR for a minimal CurrentEpochState:
    //   array(4) [accountState, ledgerState, snapshots, nonMyopic]
    //
    // accountState = array(2) [uint(100), uint(200)]
    //   0x82 0x18 0x64 0x18 0xC8
    //
    // ledgerState = array(2) [utxoState, certState]
    //   utxoState = array(5) [map(0), uint(0), uint(0), array(0), array(0)]
    //     0x85 0xA0 0x00 0x00 0x80 0x80
    //   certState = array(0)  0x80
    //   → 0x82 0x85 0xA0 0x00 0x00 0x80 0x80 0x80
    //
    // snapshots = array(4) [array(0), array(0), array(0), uint(0)]
    //   0x84 0x80 0x80 0x80 0x00
    //
    // nonMyopic = array(2) [map(0), uint(0)]
    //   0x82 0xA0 0x00
    private static let minimalCBOR: [UInt8] = [
        0x84,                                               // array(4)
        0x82, 0x18, 0x64, 0x18, 0xC8,                      // accountState [100, 200]
        0x82, 0x85, 0xA0, 0x00, 0x00, 0x80, 0x80, 0x80,    // ledgerState
        0x84, 0x80, 0x80, 0x80, 0x00,                      // snapshots
        0x82, 0xA0, 0x00,                                  // nonMyopic
    ]

    @Test("decodes accountState fields correctly")
    func decodesAccountState() throws {
        let state = try CurrentEpochState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.accountState.treasury == 100)
        #expect(state.accountState.reserves == 200)
    }

    @Test("decodes zero deposited and fees from minimal ledgerState")
    func decodesLedgerStateScalars() throws {
        let state = try CurrentEpochState.fromCBOR(data: Data(Self.minimalCBOR))
        #expect(state.ledgerState.deposited == 0)
        #expect(state.ledgerState.fees == 0)
        #expect(state.ledgerState.donation == 0)
    }

    @Test("decodes deposited and fees from a ledgerState with non-zero values")
    func decodesNonZeroLedgerStateScalars() throws {
        // LedgerState = [ [utxo, deposited, fees, govState, stakeDistr], certState ]
        let utxoState = Primitive.list([
            .dict([:]),             // utxo
            .uint(5_000_000_000),   // deposited
            .uint(1_234_567),       // fees
            .list([]),              // govState
            .list([]),              // stakeDistr
        ])
        let ledger = Primitive.list([utxoState, .list([])])
        let primitive = Primitive.list([
            .list([.uint(1), .uint(2)]),  // accountState
            ledger,
            .list([.list([]), .list([]), .list([]), .uint(999)]),  // snapshots
            .list([.dict([:]), .uint(42)]),                        // nonMyopic
        ])
        let state = try CurrentEpochState(from: primitive)
        #expect(state.ledgerState.deposited == 5_000_000_000)
        #expect(state.ledgerState.fees == 1_234_567)
        #expect(state.snapshots.fee == 999)
        #expect(state.nonMyopic.rewardPot == 42)
    }

    @Test("decodes donation from 6-element UTxO state (Conway)")
    func decodesConwayDonation() throws {
        let utxoState = Primitive.list([
            .dict([:]),             // utxo
            .uint(0),               // deposited
            .uint(0),               // fees
            .list([]),              // govState
            .list([]),              // stakeDistr
            .uint(888),             // donation (Conway)
        ])
        let primitive = Primitive.list([
            .list([.uint(0), .uint(0)]),
            .list([utxoState, .list([])]),
            .list([.list([]), .list([]), .list([]), .uint(0)]),
            .list([.dict([:]), .uint(0)]),
        ])
        let state = try CurrentEpochState(from: primitive)
        #expect(state.ledgerState.donation == 888)
    }

    @Test("decodes 5-element EpochSnapshots (newer node with markPoolDistr)")
    func decodes5ElementSnapshots() throws {
        let primitive = Primitive.list([
            .list([.uint(0), .uint(0)]),  // accountState
            .list([
                .list([.dict([:]), .uint(0), .uint(0), .list([]), .list([])]),
                .list([]),
            ]),                           // ledgerState
            // 5-element: [mark, markPoolDistr, set, go, fee]
            .list([.list([]), .dict([:]), .list([]), .list([]), .uint(500)]),
            .list([.dict([:]), .uint(0)]),
        ])
        let state = try CurrentEpochState(from: primitive)
        #expect(state.snapshots.fee == 500)
        #expect(state.snapshots.markPoolDistr != nil)
    }

    @Test("round-trip through toPrimitive preserves all typed values")
    func roundTripsAllFields() throws {
        let state = try CurrentEpochState.fromCBOR(data: Data(Self.minimalCBOR))
        let roundTripped = try CurrentEpochState(from: try state.toPrimitive())
        #expect(state == roundTripped)
        #expect(roundTripped.ledgerState.deposited == 0)
        #expect(roundTripped.snapshots.fee == 0)
        #expect(roundTripped.nonMyopic.rewardPot == 0)
    }

    @Test("init(from:) throws on non-list primitive")
    func throwsOnNonList() {
        #expect(throws: (any Error).self) {
            _ = try CurrentEpochState(from: .uint(0))
        }
    }

    @Test("init(from:) throws when array has fewer than 4 elements")
    func throwsOnShortArray() {
        #expect(throws: (any Error).self) {
            _ = try CurrentEpochState(from: .list([
                .list([.uint(0), .uint(0)]),
                .list([]),
            ]))
        }
    }
}
