import Foundation
import SwiftCardanoCore

/// State for a single DRep.
public struct DRepStateEntry: Serializable {
    /// The DRep this entry describes.
    public let drep: DRep
    /// Optional anchor (URL + data hash); nil if the DRep has no anchor.
    public let anchor: LedgerAnchor?
    /// Registration deposit in lovelace.
    public let deposit: UInt64
    /// Epoch at which the DRep registration expires.
    public let expiry: UInt64

    public init(drep: DRep, anchor: LedgerAnchor?, deposit: UInt64, expiry: UInt64) {
        self.drep = drep
        self.anchor = anchor
        self.deposit = deposit
        self.expiry = expiry
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 4 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "DRepStateEntry: expected [drep, expiry, anchor?, deposit]")
        }
        drep = try DRep(from: f[0])
        switch f[1] {
        case .uint(let u):              expiry = UInt64(u)
        case .int(let i) where i >= 0:  expiry = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepStateEntry: expected uint expiry")
        }
        anchor = (f[2] == .null) ? nil : (try? LedgerAnchor(from: f[2]))
        switch f[3] {
        case .uint(let u):              deposit = UInt64(u)
        case .int(let i) where i >= 0:  deposit = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepStateEntry: expected uint deposit")
        }
    }

    public func toPrimitive() throws -> Primitive {
        let anchorPrim: Primitive = try anchor.map { try $0.toPrimitive() } ?? .null
        return .list([
            try drep.toPrimitive(),
            .uint(UInt(expiry)),
            anchorPrim,
            .uint(UInt(deposit)),
        ])
    }

    public static func == (lhs: DRepStateEntry, rhs: DRepStateEntry) -> Bool {
        (try? lhs.drep.toPrimitive()) == (try? rhs.drep.toPrimitive())
            && lhs.anchor == rhs.anchor
            && lhs.deposit == rhs.deposit
            && lhs.expiry == rhs.expiry
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? drep.toPrimitive() { p.hash(into: &hasher) }
        anchor.hash(into: &hasher)
        deposit.hash(into: &hasher)
        expiry.hash(into: &hasher)
    }
}

/// Map of DRep credentials to their current on-chain state.
///
/// Returned by `GetDRepState` (query tag 25).
/// Wire format: `{ drep_credential → [expiry, anchor | null, deposit] }`
public struct DRepState: Serializable {
    public let entries: [DRepStateEntry]

    public init(entries: [DRepStateEntry]) {
        self.entries = entries
    }

    public init(from primitive: Primitive) throws {
        let pairs: [(Primitive, Primitive)]
        switch primitive {
        case .dict(let d): pairs = Array(d)
        case .orderedDict(let d): pairs = d.map { ($0.key, $0.value) }
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepState: expected map")
        }
        entries = try pairs.map { (key, value) in
            guard case .list(let elems) = value, elems.count >= 3 else {
                throw LedgerStateDecodingError.unexpectedFormat("DRepState: expected [expiry, anchor?, deposit, ...]")
            }
            let drep = try DRep(from: key)
            // Wire format: [expiry: EpochNo, anchor: StrictMaybe Anchor, deposit: Coin, ...]
            let expiry = try Self.uint(from: elems[0])
            // StrictMaybe Anchor: encoded as [] (Nothing) or [anchor] (Just)
            let anchor: LedgerAnchor? = try Self.parseMaybeAnchor(from: elems[1])
            let deposit = try Self.uint(from: elems[2])
            return DRepStateEntry(drep: drep, anchor: anchor, deposit: deposit, expiry: expiry)
        }
    }

    public func toPrimitive() throws -> Primitive {
        var pairs: [(Primitive, Primitive)] = []
        for entry in entries {
            let key = try entry.drep.toPrimitive()
            let anchorPrim: Primitive
            if let a = entry.anchor {
                anchorPrim = .list([.list([.string(a.url), .bytes(a.dataHash)])])
            } else {
                anchorPrim = .list([])
            }
            let value = Primitive.list([.uint(UInt(entry.expiry)), anchorPrim, .uint(UInt(entry.deposit))])
            pairs.append((key, value))
        }
        return .frozenDict(Dictionary(uniqueKeysWithValues: pairs))
    }

    public func hash(into hasher: inout Hasher) {
        entries.hash(into: &hasher)
    }

    public static func == (lhs: DRepState, rhs: DRepState) -> Bool {
        lhs.entries == rhs.entries
    }

    private static func uint(from p: Primitive) throws -> UInt64 {
        switch p {
        case .uint(let v): return UInt64(v)
        case .int(let v) where v >= 0: return UInt64(v)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepState: expected uint, got \(p)")
        }
    }

    // StrictMaybe Anchor: [] = Nothing (nil), [anchor] = Just (some)
    private static func parseMaybeAnchor(from p: Primitive) throws -> LedgerAnchor? {
        guard case .list(let elems) = p else {
            if p == .null { return nil }
            return nil
        }
        guard let anchorPrim = elems.first else { return nil }
        return try parseAnchor(from: anchorPrim)
    }

    private static func parseAnchor(from p: Primitive) throws -> LedgerAnchor {
        let elems: [Primitive]
        if case .list(let e) = p {
            elems = e
        } else if case .cborTag(let tag) = p, case .list(let e) = tag.value {
            elems = e
        } else {
            throw LedgerStateDecodingError.unexpectedFormat("DRepState: anchor must be a list")
        }
        guard elems.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat("DRepState: anchor must have [url, dataHash]")
        }
        let url: String
        switch elems[0] {
        case .string(let s): url = s
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepState: anchor URL must be a string")
        }
        let dataHash: Data
        switch elems[1] {
        case .bytes(let d): dataHash = d
        case .byteArray(let b): dataHash = Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("DRepState: anchor data hash must be bytes")
        }
        return LedgerAnchor(url: url, dataHash: dataHash)
    }
}
