import Foundation
import SwiftCardanoCore

// MARK: - IncrementalStakeEntry

/// A single entry in the incremental stake credentials map.
public struct IncrementalStakeEntry: Sendable {
    /// The stake credential.
    public let credential: StakeCredential
    /// Accumulated stake in lovelace.
    public let lovelace: UInt64

    public init(credential: StakeCredential, lovelace: UInt64) {
        self.credential = credential
        self.lovelace = lovelace
    }
}

extension IncrementalStakeEntry: Equatable {
    public static func == (lhs: IncrementalStakeEntry, rhs: IncrementalStakeEntry) -> Bool {
        (try? lhs.credential.toPrimitive()) == (try? rhs.credential.toPrimitive())
            && lhs.lovelace == rhs.lovelace
    }
}

extension IncrementalStakeEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        if let p = try? credential.toPrimitive() { p.hash(into: &hasher) }
        lovelace.hash(into: &hasher)
    }
}

// MARK: - IncrementalStakePointerEntry

/// A single entry in the (legacy) stake-pointer lovelace map.
public struct IncrementalStakePointerEntry: Sendable {
    /// The stake pointer (slot, txIndex, certIndex).
    public let pointer: StakePointer
    /// Lovelace held at this pointer.
    public let lovelace: UInt64

    public init(pointer: StakePointer, lovelace: UInt64) {
        self.pointer = pointer
        self.lovelace = lovelace
    }
}

extension IncrementalStakePointerEntry: Equatable {
    public static func == (lhs: IncrementalStakePointerEntry, rhs: IncrementalStakePointerEntry) -> Bool {
        lhs.pointer == rhs.pointer && lhs.lovelace == rhs.lovelace
    }
}

extension IncrementalStakePointerEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        pointer.hash(into: &hasher)
        lovelace.hash(into: &hasher)
    }
}

// MARK: - IncrementalStake

/// Incremental stake distribution accumulated from UTxO inputs within the current epoch.
///
/// Wire format: a 2-element CBOR list:
/// ```
/// [credentialsMap, pointersMap]
/// ```
/// - `credentialsMap`: `{ StakeCredential → Lovelace }` — stake indexed by credential.
/// - `pointersMap`: `{ Ptr → Lovelace }` — stake indexed by stake pointer (legacy; empty in Conway).
///
/// Both maps use the same key encoding as `GetFilteredDelegationsAndRewardAccounts`:
/// `StakeCredential` is `[0, bytes(28)]` for key hash or `[1, bytes(28)]` for script hash.
/// `Ptr` is `[slotNo, txIndex, certIndex]`.
public struct IncrementalStake: Serializable {

    /// Stake by credential — the active in-epoch accumulation.
    public let credentials: [IncrementalStakeEntry]

    /// Stake by stake pointer (legacy addressing; always empty in Conway).
    public let pointers: [IncrementalStakePointerEntry]

    public init(
        credentials: [IncrementalStakeEntry] = [],
        pointers: [IncrementalStakePointerEntry] = []
    ) {
        self.credentials = credentials
        self.pointers    = pointers
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "IncrementalStake: expected [credentialsMap, pointersMap]")
        }
        credentials = try Self.parseCredentialsMap(f[0])
        pointers    = try Self.parsePointersMap(f[1])
    }

    public func toPrimitive() throws -> Primitive {
        var credPairs: [(Primitive, Primitive)] = []
        for entry in credentials {
            credPairs.append((try entry.credential.toPrimitive(), .uint(UInt(entry.lovelace))))
        }
        var ptrPairs: [(Primitive, Primitive)] = []
        for entry in pointers {
            ptrPairs.append((entry.pointer.toPrimitive(), .uint(UInt(entry.lovelace))))
        }
        return .list([
            .frozenDict(Dictionary(uniqueKeysWithValues: credPairs)),
            .frozenDict(Dictionary(uniqueKeysWithValues: ptrPairs)),
        ])
    }

    // MARK: - Private helpers

    private static func parseCredentialsMap(_ primitive: Primitive) throws -> [IncrementalStakeEntry] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "IncrementalStake: credentialsMap must be a CBOR map")
        }
        return try pairs.map { (key, value) in
            let credential = try StakeCredential(from: key)
            let lovelace: UInt64
            switch value {
            case .uint(let v): lovelace = UInt64(v)
            case .int(let v) where v >= 0: lovelace = UInt64(v)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "IncrementalStake: credential lovelace must be uint")
            }
            return IncrementalStakeEntry(credential: credential, lovelace: lovelace)
        }
    }

    private static func parsePointersMap(
        _ primitive: Primitive
    ) throws -> [IncrementalStakePointerEntry] {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d):        pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        case .frozenDict(let d):  pairs = Array(d)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "IncrementalStake: pointersMap must be a CBOR map")
        }
        return try pairs.map { (key, value) in
            let ptr = try StakePointer.from(key)
            let lovelace: UInt64
            switch value {
            case .uint(let v): lovelace = UInt64(v)
            case .int(let v) where v >= 0: lovelace = UInt64(v)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "IncrementalStake: pointer lovelace must be uint")
            }
            return IncrementalStakePointerEntry(pointer: ptr, lovelace: lovelace)
        }
    }
}

extension IncrementalStake: Equatable {
    public static func == (lhs: IncrementalStake, rhs: IncrementalStake) -> Bool {
        lhs.credentials == rhs.credentials && lhs.pointers == rhs.pointers
    }
}

extension IncrementalStake: Hashable {
    public func hash(into hasher: inout Hasher) {
        credentials.count.hash(into: &hasher)
    }
}
