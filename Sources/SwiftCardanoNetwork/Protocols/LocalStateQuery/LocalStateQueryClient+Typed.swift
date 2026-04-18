import Foundation
import NIOCore
import SwiftCardanoCore

// MARK: - RawResult decoding

extension RawResult {

    /// Decode the raw CBOR result into any `CBORSerializable` type from SwiftCardanoCore.
    ///
    /// ```swift
    /// let params = try result.decode(ProtocolParameters.self)
    /// ```
    public func decode<T: CBORSerializable>(_ type: T.Type) throws -> T {
        let data = Data(rawCBOR.readableBytesView)
        return try T.fromCBOR(data: data)
    }

    /// Decode the raw CBOR result as a CBOR-map–encoded UTxO set.
    ///
    /// The Ouroboros node returns UTxO query results as a CBOR map:
    /// `{ TransactionInput → TransactionOutput }`.
    /// This helper iterates the map and assembles `[UTxO]`.
    public func decodeUTxOs() throws -> [UTxO] {
        var buf = rawCBOR
        // The node may or may not wrap the map in an outer Tag; skip it if present.
        if CBORLite.peekMajorType(from: buf) == CBORLite.majorTag {
            _ = try CBORLite.readTag(from: &buf)
        }
        let pairCount = try CBORLite.readMapHeader(from: &buf)
        var utxos: [UTxO] = []
        utxos.reserveCapacity(pairCount)
        for _ in 0..<pairCount {
            let keyData   = Data(try CBORLite.readValueBuffer(from: &buf).readableBytesView)
            let valueData = Data(try CBORLite.readValueBuffer(from: &buf).readableBytesView)
            let input  = try TransactionInput.fromCBOR(data: keyData)
            let output = try TransactionOutput.fromCBOR(data: valueData)
            utxos.append(UTxO(input: input, output: output))
        }
        return utxos
    }
}

// MARK: - Typed query overloads

extension LocalStateQueryClient {

    // MARK: UTxO

    /// Query the UTxO set filtered to the given addresses.
    public func queryUTxO(for addresses: [Address]) async throws -> [UTxO] {
        let result = try await query(.utxoByAddress(addresses))
        return try result.decodeUTxOs()
    }

    /// Query the UTxO set filtered to the given transaction inputs.
    public func queryUTxO(for inputs: [TransactionInput]) async throws -> [UTxO] {
        let q = try LedgerQuery.utxoByTxIn(inputs)
        let result = try await query(q)
        return try result.decodeUTxOs()
    }

    // MARK: Protocol parameters

    /// Query the current protocol parameters, decoded from the node's CBOR response.
    ///
    /// The node returns a Conway CDDL integer-keyed map which matches the
    /// `CBORSerializable` conformance on `ProtocolParameters`.
    public func queryProtocolParameters() async throws -> ProtocolParameters {
        let result = try await query(.currentProtocolParameters)
        return try result.decode(ProtocolParameters.self)
    }

    /// Query the current protocol parameters and return the raw CBOR result.
    ///
    /// Use this when you need access to the raw bytes before decoding.
    public func queryProtocolParametersRaw() async throws -> RawResult {
        try await query(.currentProtocolParameters)
    }

    // MARK: Ledger tip

    /// Query the current ledger tip as a `Point`.
    ///
    /// The node returns a CBOR `[slot, hash]` pair; this decodes it using CBORLite
    /// and assembles the existing `Point` type (no new dependency on CardanoCore).
    public func queryLedgerTip() async throws -> Point {
        let result = try await query(.ledgerTip)
        var buf = result.rawCBOR
        let count = try CBORLite.readArrayHeader(from: &buf)
        guard count == 2 else {
            throw LocalStateQueryError.unexpectedArrayLength(count)
        }
        let slot = try CBORLite.readUInt(from: &buf)
        let hash = try CBORLite.readByteString(from: &buf)
        return .blockPoint(slot: slot, hash: hash)
    }

    // MARK: Epoch

    /// Query the current epoch number.
    public func queryEpochNo() async throws -> UInt64 {
        let result = try await query(.epochNo)
        var buf = result.rawCBOR
        return try CBORLite.readUInt(from: &buf)
    }

    // MARK: Stake distribution

    /// Query the current stake distribution, decoded as raw CBOR.
    ///
    /// Use `result.decode(StakeDistribution.self)` if SwiftCardanoCore exposes
    /// a `StakeDistribution` type; otherwise inspect `rawCBOR` directly.
    public func queryStakeDistribution() async throws -> RawResult {
        try await query(.stakeDistribution)
    }

    // MARK: Governance (Conway)

    /// Query the current Conway governance state as raw CBOR.
    public func queryGovernanceState() async throws -> RawResult {
        try await query(.governanceState)
    }
}
