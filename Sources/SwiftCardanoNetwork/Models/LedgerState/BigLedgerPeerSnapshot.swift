import Foundation
import SwiftCardanoCore

// MARK: - LedgerPeerRelay

/// A single network relay address for a ledger peer.
///
/// Wire: list[3]: [uint(type), uint(port), address]
///
/// Observed relay types on mainnet/testnet:
///   type 0 — DNS hostname: address = bytes(hostname_utf8)
///   type 1 — IPv4 address: address = indefiniteList([uint(b0), uint(b1), uint(b2), uint(b3)])
public struct LedgerPeerRelay: Sendable {
    /// Human-readable address — DNS hostname (e.g. "relay.example.com")
    /// or dot-notation IPv4 (e.g. "73.54.73.48").
    public let address: String
    /// TCP port for this relay.
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

extension LedgerPeerRelay: Equatable {}
extension LedgerPeerRelay: Hashable {}

// MARK: - LedgerPeer

/// A single ledger peer entry with its stake weights and relay addresses.
///
/// Wire: list[2]:
///   [0] AccumulatedRelativeStake: list[2]: [num: uint, den: uint]
///   [1] list[2]:
///       [0] PoolStake (RelativeStake): list[2]: [num: uint, den: uint]
///       [1] indefiniteList of LedgerPeerRelay
///
/// The `accumulatedRelativeStake` is the cumulative fraction up to and including this pool.
/// The `relativeStake` is this pool's individual contribution.
public struct LedgerPeer: Sendable {
    /// Cumulative relative stake up to and including this pool.
    public let accumulatedRelativeStake: UnitInterval
        /// This pool's individual relative stake.
    public let relativeStake: UnitInterval
    /// Network relay addresses for this pool.
    public let relays: [LedgerPeerRelay]

    public init(accumulatedRelativeStake: UnitInterval, relativeStake: UnitInterval, relays: [LedgerPeerRelay]) {
        self.accumulatedRelativeStake = accumulatedRelativeStake
        self.relativeStake = relativeStake
        self.relays = relays
    }
}

extension LedgerPeer: Equatable {}
extension LedgerPeer: Hashable {}

// MARK: - BigLedgerPeerSnapshot

/// A snapshot of big ledger peers for bootstrapping peer selection.
///
/// Returned by `GetBigLedgerPeerSnapshot` (query tag 34).
///
/// Big ledger peers are pools whose combined stake exceeds approximately 50% of total
/// active stake. New nodes use this snapshot for initial peer discovery before they
/// have synced enough chain state to perform full peer selection.
///
/// Wire format (snapshot version 1 — pre-NtCv23 nodes):
///   list[2]:
///     [0] uint(1)       — snapshot encoding version
///     [1] list[2]:
///         [0] WithOrigin(SlotNo):
///                 Origin:  list[1]: [uint(0)]
///                 At(s):   list[2]: [uint(1), uint(s)]
///         [1] indefiniteList of v1-shaped peers
///                 list[2]: [accStake list[2], list[2]: [poolStake list[2], relays]]
///
/// Wire format (snapshot version 2 — cardano-node 10.7.0+, NtCv23 SRV form):
///   list[2]:
///     [0] uint(2)       — snapshot encoding version
///     [1] list[3]:
///         [0] Tip — list[3]: [uint(1), slot:uint, hash:bytes(32)]
///                   (or list[1]: [uint(0)] for genesis/origin — not yet observed
///                   in the wild; treated symmetrically with the WithOrigin path)
///         [1] uint — peer count (advisory; we count peers by length anyway)
///         [2] indefiniteList of v2-shaped peers
///                 list[3]: [accStake list[2], poolStake list[2], relays]
public struct BigLedgerPeerSnapshot: Serializable {
    /// Slot when the snapshot was taken (nil = genesis/origin).
    public let snapshotSlot: UInt64?
    /// Block-hash anchor when the snapshot was taken.  Always nil for v1
    /// snapshots; populated for v2 (NtCv23+) snapshots.
    public let snapshotHash: Data?
    /// Ledger peers, sorted by ascending accumulated relative stake.
    public let peers: [LedgerPeer]

    public init(snapshotSlot: UInt64?, snapshotHash: Data? = nil, peers: [LedgerPeer]) {
        self.snapshotSlot = snapshotSlot
        self.snapshotHash = snapshotHash
        self.peers = peers
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let top) = primitive, top.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list[2+], got \(primitive)")
        }
        let snapshotVersion: UInt64
        switch top[0] {
        case .uint(let u): snapshotVersion = u
        case .int(let i) where i >= 0: snapshotVersion = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected uint snapshot version, got \(top[0])")
        }
        guard case .list(let inner) = top[1] else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list inner content, got \(top[1])")
        }
        switch snapshotVersion {
        case 1:
            guard inner.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v1: expected inner list[2+], got count \(inner.count)")
            }
            snapshotSlot = try Self.decodeWithOriginSlot(inner[0])
            snapshotHash = nil
            peers = try Self.decodePeers(inner[1], shape: .v1)
        case 2:
            guard inner.count >= 3 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v2: expected inner list[3+], got count \(inner.count)")
            }
            let (slot, hash) = try Self.decodeTip(inner[0])
            snapshotSlot = slot
            snapshotHash = hash
            // inner[1] is an advisory peer count we ignore.
            peers = try Self.decodePeers(inner[2], shape: .v2)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: unknown snapshot version \(snapshotVersion)")
        }
    }

    public func toPrimitive() throws -> Primitive {
        // Always emit v1 — this library doesn't currently produce snapshots for
        // node-side use.  Decoding is what matters.
        let slotPrim = Self.encodeWithOriginSlot(snapshotSlot)
        let peersPrim = Primitive.indefiniteList(IndefiniteList(try peers.map { try Self.encodePeer($0) }))
        return .list([.uint(1), .list([slotPrim, peersPrim])])
    }

    // MARK: - Tip (v2 anchor)

    private static func decodeTip(_ p: Primitive) throws -> (slot: UInt64?, hash: Data?) {
        guard case .list(let items) = p, !items.isEmpty else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot v2: expected Tip list, got \(p)")
        }
        switch items[0] {
        case .uint(0), .int(0):
            return (nil, nil)  // Origin
        case .uint(1), .int(1):
            guard items.count >= 3 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v2: Tip At missing slot or hash (count=\(items.count))")
            }
            let slot: UInt64
            switch items[1] {
            case .uint(let u): slot = UInt64(u)
            case .int(let i) where i >= 0: slot = UInt64(i)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v2: expected uint slot, got \(items[1])")
            }
            guard case .bytes(let h) = items[2] else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v2: expected bytes hash, got \(items[2])")
            }
            return (slot, h)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot v2: unexpected Tip tag \(items[0])")
        }
    }

    // MARK: - WithOrigin(SlotNo)

    private static func decodeWithOriginSlot(_ p: Primitive) throws -> UInt64? {
        guard case .list(let items) = p, !items.isEmpty else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected WithOrigin list for slot, got \(p)")
        }
        switch items[0] {
        case .uint(0), .int(0):
            return nil  // Origin
        case .uint(1), .int(1):
            guard items.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot: WithOrigin At missing slot value")
            }
            switch items[1] {
            case .uint(let u): return UInt64(u)
            case .int(let i) where i >= 0: return UInt64(i)
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot: expected uint slot value, got \(items[1])")
            }
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: unexpected WithOrigin tag \(items[0])")
        }
    }

    private static func encodeWithOriginSlot(_ slot: UInt64?) -> Primitive {
        guard let slot else { return .list([.uint(0)]) }
        return .list([.uint(1), .uint(UInt64(slot))])
    }

    // MARK: - Peers

    private enum PeerShape { case v1, v2 }

    private static func decodePeers(_ p: Primitive, shape: PeerShape) throws -> [LedgerPeer] {
        let items: [Primitive]
        switch p {
        case .list(let l): items = l
        case .indefiniteList(let l): items = Array(l)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list for peers, got \(p)")
        }
        return try items.map { try decodePeer($0, shape: shape) }
    }

    private static func decodePeer(_ p: Primitive, shape: PeerShape) throws -> LedgerPeer {
        guard case .list(let f) = p else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list for peer, got \(p)")
        }
        switch shape {
        case .v1:
            // list[2]: [accumulatedRelativeStake, list[2]: [relativeStake, relays]]
            guard f.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v1: expected list[2+] for peer, got count \(f.count)")
            }
            let accStake = try decodeRational(f[0], label: "accumulatedRelativeStake")
            guard case .list(let inner) = f[1], inner.count >= 2 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v1: expected inner list[2+], got \(f[1])")
            }
            let poolStake = try decodeRational(inner[0], label: "relativeStake")
            let relays = try decodeRelays(inner[1])
            return LedgerPeer(accumulatedRelativeStake: accStake, relativeStake: poolStake, relays: relays)
        case .v2:
            // list[3]: [accumulatedRelativeStake, relativeStake, relays] — flattened
            guard f.count >= 3 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot v2: expected list[3+] for peer, got count \(f.count)")
            }
            let accStake = try decodeRational(f[0], label: "accumulatedRelativeStake")
            let poolStake = try decodeRational(f[1], label: "relativeStake")
            let relays = try decodeRelays(f[2])
            return LedgerPeer(accumulatedRelativeStake: accStake, relativeStake: poolStake, relays: relays)
        }
    }

    private static func decodeRational(_ p: Primitive, label: String) throws -> UnitInterval {
        guard case .list(let f) = p, f.count >= 2,
              let num = f[0].uint64Value, let den = f[1].uint64Value else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected rational list[2] for \(label), got \(p)")
        }
        return UnitInterval(numerator: num, denominator: den)
    }

    private static func decodeRelays(_ p: Primitive) throws -> [LedgerPeerRelay] {
        let items: [Primitive]
        switch p {
        case .list(let l): items = l
        case .indefiniteList(let l): items = Array(l)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list for relays, got \(p)")
        }
        return try items.map { try decodeRelay($0) }
    }

    private static func decodeRelay(_ p: Primitive) throws -> LedgerPeerRelay {
        // list[3]: [uint(type), uint(port), address]
        // type 0 — DNS hostname: address = bytes(utf8)
        // type 1 — IPv4 address: address = indefiniteList([uint(b0..b3)])
        guard case .list(let f) = p, f.count >= 3 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list[3+] for relay, got \(p)")
        }
        guard let port = portValue(f[1]) else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected uint port in relay, got \(f[1])")
        }
        let relayType: UInt64
        switch f[0] {
        case .uint(let u): relayType = u
        case .int(let i) where i >= 0: relayType = UInt64(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected uint relay type, got \(f[0])")
        }
        let address = try addressFromPrimitive(f[2], type: relayType)
        return LedgerPeerRelay(address: address, port: port)
    }

    private static func addressFromPrimitive(_ p: Primitive, type relayType: UInt64) throws -> String {
        switch relayType {
        case 0:
            // DNS hostname stored as bytes (ASCII/UTF-8)
            switch p {
            case .bytes(let d):
                guard let s = String(bytes: d, encoding: .utf8) else {
                    throw LedgerStateDecodingError.unexpectedFormat(
                        "BigLedgerPeerSnapshot: hostname bytes not valid UTF-8")
                }
                return s
            case .string(let s):
                return s
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot: type-0 relay expected bytes hostname, got \(p)")
            }
        case 1:
            // IPv4 address: indefiniteList of 4 uint8 values
            let octets: [UInt64]
            switch p {
            case .indefiniteList(let il):
                octets = try Array(il).map {
                    guard case .uint(let b) = $0, b <= 255 else {
                        throw LedgerStateDecodingError.unexpectedFormat(
                            "BigLedgerPeerSnapshot: expected uint8 in IPv4, got \($0)")
                    }
                    return b
                }
            case .bytes(let d) where d.count == 4:
                octets = d.map { UInt64($0) }
            default:
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot: type-1 relay expected IPv4 data, got \(p)")
            }
            guard octets.count == 4 else {
                throw LedgerStateDecodingError.unexpectedFormat(
                    "BigLedgerPeerSnapshot: IPv4 must have 4 octets, got \(octets.count)")
            }
            return "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: unsupported relay type \(relayType)")
        }
    }

    private static func portValue(_ p: Primitive) -> UInt16? {
        switch p {
        case .uint(let u) where u <= UInt(UInt16.max): return UInt16(u)
        case .int(let i) where i >= 0 && i <= Int(UInt16.max): return UInt16(i)
        default: return nil
        }
    }

    private static func encodePeer(_ peer: LedgerPeer) throws -> Primitive {
        let accNum = UInt64(peer.accumulatedRelativeStake.numerator)
        let accDen = UInt64(peer.accumulatedRelativeStake.denominator)
        let poolNum = UInt64(peer.relativeStake.numerator)
        let poolDen = UInt64(peer.relativeStake.denominator)
        let relaysPrim = Primitive.indefiniteList(IndefiniteList(peer.relays.map { relay in
            Primitive.list([
                .uint(0),
                .uint(UInt64(relay.port)),
                .bytes(Data(relay.address.utf8)),
            ])
        }))
        return .list([
            .list([.uint(accNum), .uint(accDen)]),
            .list([.list([.uint(poolNum), .uint(poolDen)]), relaysPrim]),
        ])
    }

    public static func == (lhs: BigLedgerPeerSnapshot, rhs: BigLedgerPeerSnapshot) -> Bool {
        lhs.snapshotSlot == rhs.snapshotSlot && lhs.peers == rhs.peers
    }

    public func hash(into hasher: inout Hasher) {
        snapshotSlot.hash(into: &hasher)
        peers.hash(into: &hasher)
    }
}
