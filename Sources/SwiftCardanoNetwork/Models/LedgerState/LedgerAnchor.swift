import Foundation

/// An anchor consisting of a URL and a 32-byte data hash.
///
/// Used by governance primitives such as the constitution, DRep registrations,
/// and proposal procedures.
public struct LedgerAnchor: Sendable, Equatable, Hashable {
    /// The URL pointing to the anchor document.
    public let url: String
    /// The 32-byte Blake2b-256 hash of the anchor document.
    public let dataHash: Data

    public init(url: String, dataHash: Data) {
        self.url = url
        self.dataHash = dataHash
    }
}
