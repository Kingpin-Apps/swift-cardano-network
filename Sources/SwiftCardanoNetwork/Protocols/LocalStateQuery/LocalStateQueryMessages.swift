import NIOCore

// MARK: - AcquirePoint

/// Specifies the chain point to acquire for a `LocalStateQuery` session.
public enum AcquirePoint: Sendable {
    /// Acquire a volatile snapshot at the node's current chain tip.
    /// This is the most common acquire mode for wallet and explorer use cases.
    case volatileTip
    /// Acquire an immutable snapshot at a specific chain point.
    case specific(Point)
}

extension AcquirePoint: CustomStringConvertible {
    public var description: String {
        switch self {
        case .volatileTip:         return "volatileTip"
        case .specific(let point): return "specific(\(point))"
        }
    }
}

// MARK: - AcquireFailure

/// The reason the node could not acquire the requested chain point.
public enum AcquireFailure: UInt64, Sendable {
    /// The requested point has been discarded from the node's volatile DB (too old).
    case pointTooOld     = 0
    /// The requested point is not on the node's current chain.
    case pointNotOnChain = 1
}

// MARK: - Protocol messages

/// The complete LocalStateQuery mini-protocol message set (NtC only, protocol ID 7).
public enum LocalStateQueryMessage: Sendable {

    // MARK: Client → Server

    /// Acquire a snapshot at a specific chain point.
    case acquire(Point)
    /// Acquire a snapshot at the node's current volatile tip (no specific point).
    case acquireVolatileTip
    /// Re-acquire a snapshot at a new chain point (from `Acquired` state).
    case reAcquire(Point)
    /// Run an era-tagged ledger query against the acquired snapshot.
    case query(RawQuery)
    /// Release the current acquired snapshot, returning to `Idle`.
    case release
    /// Terminate the protocol (from `Idle` state).
    case done

    // MARK: Server → Client

    /// The requested chain point was successfully acquired.
    case acquired
    /// The node could not acquire the requested chain point.
    case failure(AcquireFailure)
    /// The result of a ledger query.
    case result(RawResult)
}

// MARK: - Errors

/// Errors raised by `LocalStateQueryClient` and `LocalStateQueryCodec`.
public enum LocalStateQueryError: Error, Sendable {
    /// The node rejected the acquire request.
    case acquireFailed(AcquireFailure)
    /// The CBOR message tag was not a recognised LocalStateQuery message code (0–8).
    case unknownMessageTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
    /// The acquire failure code was not 0 (PointTooOld) or 1 (PointNotOnChain).
    case unknownAcquireFailure(UInt64)
    /// The encoded point had an unexpected array length.
    case malformedPoint(arrayLength: Int)
}
