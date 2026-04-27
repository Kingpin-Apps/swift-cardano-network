import NIOCore

// MARK: - PeerAddress

/// A network address advertised by the Peer-Sharing mini-protocol (§3.11.7).
///
/// Wire CDDL:
/// ```
/// peerAddress = [0, word32, portNumber]
///             / [1, word32, word32, word32, word32, portNumber]
/// portNumber  = word16
/// ```
///
/// IPv4 addresses are carried as a single big-endian `UInt32`; IPv6 addresses
/// are carried as four big-endian `UInt32` words (high-order word first).
public enum PeerAddress: Sendable, Equatable, Hashable {
    /// IPv4 address: `addr` is the 32-bit address in host byte order
    /// (so `127.0.0.1` is `0x7F000001`).
    case ipv4(addr: UInt32, port: UInt16)

    /// IPv6 address: `addr` is the four 32-bit words of the address in
    /// host byte order, high-order word first.
    case ipv6(addr: (UInt32, UInt32, UInt32, UInt32), port: UInt16)

    public static func == (lhs: PeerAddress, rhs: PeerAddress) -> Bool {
        switch (lhs, rhs) {
        case (.ipv4(let la, let lp), .ipv4(let ra, let rp)):
            return la == ra && lp == rp
        case (.ipv6(let la, let lp), .ipv6(let ra, let rp)):
            return la.0 == ra.0 && la.1 == ra.1 && la.2 == ra.2 && la.3 == ra.3 && lp == rp
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .ipv4(let addr, let port):
            hasher.combine(0)
            hasher.combine(addr)
            hasher.combine(port)
        case .ipv6(let addr, let port):
            hasher.combine(1)
            hasher.combine(addr.0)
            hasher.combine(addr.1)
            hasher.combine(addr.2)
            hasher.combine(addr.3)
            hasher.combine(port)
        }
    }

    /// The transport port.
    public var port: UInt16 {
        switch self {
        case .ipv4(_, let p): return p
        case .ipv6(_, let p): return p
        }
    }

    /// Human-readable host string (`a.b.c.d` or compact IPv6).
    public var host: String {
        switch self {
        case .ipv4(let addr, _):
            let a = (addr >> 24) & 0xFF
            let b = (addr >> 16) & 0xFF
            let c = (addr >> 8)  & 0xFF
            let d =  addr        & 0xFF
            return "\(a).\(b).\(c).\(d)"

        case .ipv6(let addr, _):
            let groups: [UInt16] = [
                UInt16(truncatingIfNeeded: addr.0 >> 16), UInt16(truncatingIfNeeded: addr.0),
                UInt16(truncatingIfNeeded: addr.1 >> 16), UInt16(truncatingIfNeeded: addr.1),
                UInt16(truncatingIfNeeded: addr.2 >> 16), UInt16(truncatingIfNeeded: addr.2),
                UInt16(truncatingIfNeeded: addr.3 >> 16), UInt16(truncatingIfNeeded: addr.3),
            ]
            return groups.map { String($0, radix: 16) }.joined(separator: ":")
        }
    }
}

// MARK: - Protocol messages

/// The complete Peer-Sharing mini-protocol message set (§3.11, NtN only, protocol ID 10).
///
/// ## Wire tags
/// ```
/// [0, amount]        — shareRequest(amount: UInt8)
/// [1, [peerAddress]] — sharePeers([PeerAddress])
/// [2]                — done
/// ```
public enum PeerSharingMessage: Sendable {
    /// Client requests up to `amount` peers from the server.
    case shareRequest(amount: UInt8)
    /// Server replies with a list of peer addresses (size MUST NOT exceed
    /// the client's requested amount, per §3.11.2).
    case sharePeers([PeerAddress])
    /// Client terminates the protocol.
    case done
}

// MARK: - Errors

/// Errors raised by `PeerSharingClient` and `PeerSharingCodec`.
public enum PeerSharingError: Error, Sendable {
    /// The remote does not support peer sharing — either the negotiated NtN
    /// version is below 14 or the remote's `peerSharing` flag was not
    /// `PeerSharingEnabled` (§3.11.5).
    case unsupported(version: UInt16, peerSharingFlag: UInt8?)
    /// The server returned more peers than the client requested. Per §3.11.2
    /// this is a protocol error and the connection SHOULD be torn down.
    case tooManyPeers(requested: UInt8, received: Int)
    /// The CBOR message tag was not 0, 1, or 2.
    case unknownMessageTag(UInt64)
    /// A peer-address sub-array used a tag other than 0 (IPv4) or 1 (IPv6).
    case unknownAddressTag(UInt64)
    /// An array had an unexpected number of elements.
    case unexpectedArrayLength(Int)
    /// A field declared as `UInt16` overflowed (e.g. port number).
    case integerOverflow(value: UInt64, expectedBits: Int)
}
