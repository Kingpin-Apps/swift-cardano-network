import Foundation
import SwiftCardanoCore

/// The current on-chain constitution.
///
/// Returned by `GetConstitution` (query tag 23).
/// Wire format: `[anchor, script_hash | null]` where `anchor` is `[url, anchor_data_hash]`.
public struct LedgerConstitution: Serializable {
    /// The anchor with the URL and data hash of the constitution document.
    public let anchor: LedgerAnchor
    /// Optional script hash governing the constitution guard script.
    public let scriptHash: Data?

    public var anchorURL: String { anchor.url }
    public var anchorDataHash: Data { anchor.dataHash }

    public init(anchor: LedgerAnchor, scriptHash: Data?) {
        self.anchor = anchor
        self.scriptHash = scriptHash
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let elems) = primitive, elems.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat("LedgerConstitution: expected [anchor, script_hash]")
        }
        anchor = try Self.parseAnchor(from: elems[0])
        scriptHash = Self.parseOptionalBytes(from: elems[1])
    }

    public func toPrimitive() throws -> Primitive {
        let anchorPrim = Primitive.list([.string(anchor.url), .bytes(anchor.dataHash)])
        let scriptHashPrim: Primitive = scriptHash.map { .bytes($0) } ?? .null
        return .list([anchorPrim, scriptHashPrim])
    }

    private static func parseAnchor(from p: Primitive) throws -> LedgerAnchor {
        let elems: [Primitive]
        if case .list(let e) = p {
            elems = e
        } else if case .cborTag(let tag) = p, case .list(let e) = tag.value {
            elems = e
        } else {
            throw LedgerStateDecodingError.unexpectedFormat("LedgerConstitution: anchor must be a list")
        }
        guard elems.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat("LedgerConstitution: anchor must have [url, dataHash]")
        }
        let url: String
        switch elems[0] {
        case .string(let s): url = s
        default:
            throw LedgerStateDecodingError.unexpectedFormat("LedgerConstitution: anchor URL must be a text string")
        }
        let dataHash: Data
        switch elems[1] {
        case .bytes(let d): dataHash = d
        case .byteArray(let b): dataHash = Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("LedgerConstitution: anchor data hash must be bytes")
        }
        return LedgerAnchor(url: url, dataHash: dataHash)
    }

    private static func parseOptionalBytes(from p: Primitive) -> Data? {
        switch p {
        case .bytes(let d): return d
        case .byteArray(let b): return Data(b)
        case .null: return nil
        default: return nil
        }
    }
}
