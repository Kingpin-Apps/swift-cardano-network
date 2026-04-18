import Foundation
import NIOCore
import SwiftCardanoCore

extension RawBlock {

    /// Decode this raw CBOR block into a fully-typed SwiftCardanoCore `Block`.
    ///
    /// `rawCBOR` contains the CBOR-encoded block body received from the node via
    /// ChainSync.  SwiftCardanoCore's `Block.fromCBOR(data:)` expects a 5-element
    /// CBOR array `[header, bodies, witnessSets, auxiliaryData, invalidTxIndices]`.
    ///
    /// - Throws: `CardanoCoreError.deserializeError` if the bytes are not a valid block.
    public func decode() throws -> Block {
        let data = Data(rawCBOR.readableBytesView)
        return try Block.fromCBOR(data: data)
    }
}
