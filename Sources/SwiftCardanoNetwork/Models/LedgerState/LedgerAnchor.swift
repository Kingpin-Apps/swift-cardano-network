import Foundation
import SwiftCardanoCore

/// An anchor consisting of a URL and a 32-byte data hash.
///
/// Used by governance primitives such as the constitution, DRep registrations,
/// and proposal procedures.
///
/// Wire format: 2-element CBOR list `[url: text, dataHash: bytes(32)]`.
public struct LedgerAnchor: Serializable {
    /// The URL pointing to the anchor document.
    public let url: String
    /// The 32-byte Blake2b-256 hash of the anchor document.
    public let dataHash: Data

    public init(url: String, dataHash: Data) {
        self.url = url
        self.dataHash = dataHash
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let f) = primitive, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "LedgerAnchor: expected [url, dataHash]")
        }
        guard case .string(let u) = f[0] else {
            throw LedgerStateDecodingError.unexpectedFormat("LedgerAnchor: url must be string")
        }
        url = u
        switch f[1] {
        case .bytes(let d):     dataHash = d
        case .byteArray(let b): dataHash = Data(b)
        default:
            throw LedgerStateDecodingError.unexpectedFormat("LedgerAnchor: dataHash must be bytes")
        }
    }

    public func toPrimitive() throws -> Primitive {
        .list([.string(url), .bytes(dataHash)])
    }
}
