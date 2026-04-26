import Foundation
import NIOCore
import SwiftCardanoCore
import Testing

@testable import SwiftCardanoNetwork

// MARK: - LedgerQuery typed constructor tests
//
// These tests verify that each typed factory produces a RawQuery with the
// correct era and CBOR byte sequence.  We check byte-level identity against
// the known Ouroboros wire tags (pallas reference: GetLedgerTip=0, GetEpochNo=1,
// GetCurrentPParams=3, GetProposedPParamsUpdates=4, GetStakeDistribution=5,
// GetUTxOByAddress=6, GetUTxOByTxIn=15, GetGovState=24).

private let alloc = ByteBufferAllocator()

private func rawBytes(_ lq: LedgerQuery) -> [UInt8] {
    var buf = lq.rawQuery.rawCBOR
    return buf.readBytes(length: buf.readableBytes) ?? []
}

@Suite("LedgerQuery typed constructors") struct LedgerQueryTypedTests {

    @Test func ledgerTipQueryEraIsConway() {
        #expect(LedgerQuery.ledgerTip().rawQuery.era == 6)
    }

    @Test func ledgerTipQueryCBOR() {
        // Expected: CBOR array [0]  →  0x81 0x00
        let bytes = rawBytes(.ledgerTip())
        #expect(bytes == [0x81, 0x00])
    }

    @Test func epochNoQueryCBOR() {
        // Expected: CBOR array [1]  →  0x81 0x01
        let bytes = rawBytes(.epochNo())
        #expect(bytes == [0x81, 0x01])
    }

    @Test func currentProtocolParametersCBOR() {
        // Expected: CBOR array [3]  →  0x81 0x03
        let bytes = rawBytes(.currentProtocolParameters())
        #expect(bytes == [0x81, 0x03])
    }

    @Test func proposedProtocolParametersUpdatesCBOR() throws {
        // Expected: CBOR array [4]  →  0x81 0x04
        let bytes = rawBytes(try .proposedProtocolParametersUpdates())
        #expect(bytes == [0x81, 0x04])
    }

    @Test func stakeDistributionCBOR_legacy_at_v16() {
        // At NtCv9..v20 the wire form is tag 5: CBOR array [5]  →  0x81 0x05
        let bytes = rawBytes(.stakeDistribution(at: NodeToClientVersion.v16))
        #expect(bytes == [0x81, 0x05])
    }

    @Test func stakeDistributionCBOR_replacement_at_v21() {
        // At NtCv21+ the wire form switches to tag 37 (GetStakeDistribution2):
        // CBOR array [37]  →  0x81 0x18 0x25
        let bytes = rawBytes(.stakeDistribution(at: NodeToClientVersion.v21))
        #expect(bytes == [0x81, 0x18, 0x25])
    }

    @Test func stakeDistributionCBOR_replacement_at_v23() {
        // At NtCv23 same replacement tag 37 expected.
        let bytes = rawBytes(.stakeDistribution(at: NodeToClientVersion.v23))
        #expect(bytes == [0x81, 0x18, 0x25])
    }

    @Test func poolDistrCBOR_legacy_at_v16() throws {
        // At NtCv9..v20 the wire form for poolDistr(nil) is [21, []]:
        //   array(2) uint(21) array(0)  →  0x82 0x15 0x80
        let q = try LedgerQuery.poolDistr(nil, at: NodeToClientVersion.v16)
        let bytes = rawBytes(q)
        #expect(bytes == [0x82, 0x15, 0x80])
    }

    @Test func poolDistrCBOR_replacement_at_v21() throws {
        // At NtCv21+ the wire form switches to tag 36 (GetPoolDistr2):
        //   array(2) uint(36) array(0)  →  0x82 0x18 0x24 0x80
        let q = try LedgerQuery.poolDistr(nil, at: NodeToClientVersion.v21)
        let bytes = rawBytes(q)
        #expect(bytes == [0x82, 0x18, 0x24, 0x80])
    }

    @Test func genesisConfigCBOR() {
        // Expected: CBOR array [11]  →  0x81 0x0B
        let bytes = rawBytes(.genesisConfig())
        #expect(bytes == [0x81, 0x0B])
    }

    @Test func governanceStateCBOR() throws {
        // Expected: CBOR array [24]  →  0x81 0x18 0x18
        let bytes = rawBytes(try .governanceState())
        #expect(bytes == [0x81, 0x18, 0x18])
    }

    @Test func constitutionHashCBOR() throws {
        // Expected: CBOR array [23]  →  0x81 0x17
        let bytes = rawBytes(try .constitutionHash())
        #expect(bytes == [0x81, 0x17])
    }

    @Test func utxoByAddressEraIsConway() {
        let q = LedgerQuery.utxoByAddress([])
        #expect(q.rawQuery.era == 6)
    }

    @Test func utxoByAddressEmptySet() {
        // Empty: [6, tag(258, [])]
        // CBOR:  0x82 0x06  0xd9 0x01 0x02  0x80
        let bytes = rawBytes(.utxoByAddress([]))
        // Array(2), uint(6), tag(258 = 0x0102), array(0)
        #expect(bytes[0] == 0x82)  // array of 2
        #expect(bytes[1] == 0x06)  // query tag 6
        #expect(bytes[2] == 0xd9)  // 3-byte tag header
        #expect(bytes[3] == 0x01)
        #expect(bytes[4] == 0x02)  // tag 258
        #expect(bytes[5] == 0x80)  // empty array
    }

    @Test func utxoByTxInQueryTag() throws {
        let q = try LedgerQuery.utxoByTxIn([])
        #expect(q.rawQuery.era == 6)
        let bytes = rawBytes(q)
        #expect(bytes[0] == 0x82)  // array of 2
        #expect(bytes[1] == 0x0f)  // query tag 15
    }

    @Test func allSimpleQueriesHaveConwayEra() throws {
        let queries: [LedgerQuery] = [
            .ledgerTip(), .epochNo(), .currentProtocolParameters(),
            try .proposedProtocolParametersUpdates(), .stakeDistribution(),
            .genesisConfig(), try .governanceState(), try .constitutionHash(),
            try .ratifyState(at: NodeToClientVersion.v17),
        ]
        for q in queries {
            #expect(q.rawQuery.era == 6, "Expected Conway era for \(q)")
        }
    }

    @Test func rawQueryAccessorStillWorks() {
        // Existing .raw(_) path must be unaffected.
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0xDE, 0xAD])
        let lq = LedgerQuery.raw(RawQuery(era: 5, rawCBOR: buf))
        #expect(lq.rawQuery.era == 5)
        #expect(lq.rawQuery.rawCBOR.readableBytes == 2)
    }

    @Test func ratifyStateCBOR() throws {
        // Expected: CBOR array [32]  →  0x81 0x18 0x20
        let bytes = rawBytes(try .ratifyState(at: NodeToClientVersion.v17))
        #expect(bytes == [0x81, 0x18, 0x20])
    }

    @Test func utxoByTxInEmptySetCBOR() throws {
        let q = try LedgerQuery.utxoByTxIn([])
        let bytes = rawBytes(q)
        // [15, Tag258, []]  →  array(2) uint(15) tag(258) array(0)
        #expect(bytes[0] == 0x82)  // array of 2
        #expect(bytes[1] == 0x0f)  // query tag 15
        #expect(bytes[2] == 0xd9)  // 3-byte tag header
        #expect(bytes[3] == 0x01)
        #expect(bytes[4] == 0x02)  // tag 258
        #expect(bytes[5] == 0x80)  // empty array
    }

    @Test func stakePoolParamsEmptySetCBOR() throws {
        // Empty: [17, Tag258, []]
        let q = try LedgerQuery.stakePoolParams([])
        let bytes = rawBytes(q)
        #expect(bytes[0] == 0x82)  // array of 2
        #expect(bytes[1] == 0x11)  // query tag 17
        #expect(bytes[2] == 0xd9)  // tag prefix
        #expect(bytes[3] == 0x01)
        #expect(bytes[4] == 0x02)  // tag 258
        #expect(bytes[5] == 0x80)  // empty array
        #expect(q.rawQuery.era == 6)
    }

    @Test func filteredDelegationsAndRewardAccountsEmptySetCBOR() throws {
        // Empty: [10, Tag258, []]
        let q = try LedgerQuery.filteredDelegationsAndRewardAccounts([])
        let bytes = rawBytes(q)
        #expect(bytes[0] == 0x82)  // array of 2
        #expect(bytes[1] == 0x0a)  // query tag 10
        #expect(bytes[2] == 0xd9)  // tag prefix
        #expect(bytes[3] == 0x01)
        #expect(bytes[4] == 0x02)  // tag 258
        #expect(bytes[5] == 0x80)  // empty array
        #expect(q.rawQuery.era == 6)
    }

    // MARK: - Non-empty collection tests — cover loop body lines

    @Test func utxoByAddressWithOneAddressEncodesBytes() throws {
        // Create a minimal enterprise (no-staking) testnet address from a
        // VerificationKeyHash so we have a valid Address to pass.
        let keyHash = VerificationKeyHash(payload: Data(repeating: 0xAB, count: 28))
        let payment = PaymentPart.verificationKeyHash(keyHash)
        let addr = try Address(paymentPart: payment, network: .testnet)
        let bytes = rawBytes(.utxoByAddress([addr]))
        // Structure: array(2), tag 6, tag(258), array(1), bstr(<addr bytes>)
        #expect(bytes.count > 6)  // address bytes must be appended
        #expect(bytes[0] == 0x82)  // array of 2
        #expect(bytes[1] == 0x06)  // query tag 6
        #expect(bytes[5] == 0x81)  // array(1) — one item in the set
    }

    @Test func utxoByTxInWithOneInputEncodesBytes() throws {
        // Construct a valid TransactionInput and verify the CBOR contains it.
        let txId = TransactionId(payload: Data(repeating: 0xCC, count: 32))
        let input = TransactionInput(transactionId: txId, index: 0)
        let q = try LedgerQuery.utxoByTxIn([input])
        let bytes = rawBytes(q)
        // Structure: array(2), tag 15, tag(258), array(1), <input CBOR>
        #expect(bytes.count > 6)  // input CBOR must be appended
        #expect(bytes[1] == 0x0f)  // query tag 15
        #expect(bytes[5] == 0x81)  // array(1) — one item in the set
    }
}
