import NIOCore

/// A raw, era-tagged CBOR query payload for `LocalStateQuery`.
///
/// Use `swift-cardano-core` to construct well-typed queries and serialise them
/// to `rawCBOR`. The era number identifies the ledger rules the query targets:
/// ```
/// Byron=0  Shelley=1  Allegra=2  Mary=3  Alonzo=4  Babbage=5  Conway=6
/// ```
public struct RawQuery: @unchecked Sendable {
    public let era: UInt16
    public var rawCBOR: ByteBuffer

    public init(era: UInt16, rawCBOR: ByteBuffer) {
        self.era = era
        self.rawCBOR = rawCBOR
    }
}

/// A raw, era-tagged CBOR query result returned by the node.
///
/// Decode `rawCBOR` with `swift-cardano-core` to obtain a typed result struct.
public struct RawResult: @unchecked Sendable {
    public let era: UInt16
    public var rawCBOR: ByteBuffer

    public init(era: UInt16, rawCBOR: ByteBuffer) {
        self.era = era
        self.rawCBOR = rawCBOR
    }
}

/// A typed ledger query for `LocalStateQuery`.
///
/// Since query payloads are era-specific CBOR, the primary entry point is
/// `.raw(_:)`. Future versions will add strongly-typed cases once
/// `swift-cardano-core` integration is complete.
///
/// ```swift
/// var qBuf = allocator.buffer(capacity: myQueryCBOR.count)
/// qBuf.writeBytes(myQueryCBOR)
/// let query = LedgerQuery.raw(RawQuery(era: 6, rawCBOR: qBuf))
/// let result = try await client.query(query)
/// ```
public enum LedgerQuery: Sendable {
    /// A pre-serialised era-tagged query payload.
    case raw(RawQuery)
}

extension LedgerQuery {
    /// The underlying `RawQuery` regardless of which case is active.
    var rawQuery: RawQuery {
        switch self {
        case .raw(let q): return q
        }
    }
}
