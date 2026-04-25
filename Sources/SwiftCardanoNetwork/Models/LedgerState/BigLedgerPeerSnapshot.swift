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
/// Wire format: list[2]:
///   [0] uint(1)       — snapshot encoding version
///   [1] list[2]:
///       [0] WithOrigin(SlotNo) — slot when the snapshot was taken:
///               Origin:  list[1]: [uint(0)]
///               At(s):   list[2]: [uint(1), uint(s)]
///       [1] indefiniteList of LedgerPeer entries
public struct BigLedgerPeerSnapshot: CBORSerializable, Sendable {
    /// Slot when the snapshot was taken (nil = genesis/origin).
    public let snapshotSlot: UInt64?
    /// Ledger peers, sorted by ascending accumulated relative stake.
    public let peers: [LedgerPeer]

    public init(snapshotSlot: UInt64?, peers: [LedgerPeer]) {
        self.snapshotSlot = snapshotSlot
        self.peers = peers
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let top) = primitive, top.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list[2+], got \(primitive)")
        }
        guard case .list(let v1) = top[1], v1.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected v1 content list[2+], got \(top[1])")
        }
        snapshotSlot = try Self.decodeWithOriginSlot(v1[0])
        peers = try Self.decodePeers(v1[1])
    }

    public func toPrimitive() throws -> Primitive {
        let slotPrim = Self.encodeWithOriginSlot(snapshotSlot)
        let peersPrim = Primitive.indefiniteList(IndefiniteList(try peers.map { try Self.encodePeer($0) }))
        return .list([.uint(1), .list([slotPrim, peersPrim])])
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
        return .list([.uint(1), .uint(UInt(slot))])
    }

    // MARK: - Peers

    private static func decodePeers(_ p: Primitive) throws -> [LedgerPeer] {
        let items: [Primitive]
        switch p {
        case .list(let l): items = l
        case .indefiniteList(let l): items = Array(l)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list for peers, got \(p)")
        }
        return try items.map { try decodePeer($0) }
    }

    private static func decodePeer(_ p: Primitive) throws -> LedgerPeer {
        // list[2]: [accumulatedRelativeStake, list[2]: [relativeStake, relays]]
        guard case .list(let f) = p, f.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected list[2+] for peer, got \(p)")
        }
        let accStake = try decodeRational(f[0], label: "accumulatedRelativeStake")
        guard case .list(let inner) = f[1], inner.count >= 2 else {
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected inner list[2+] for (poolStake, relays), got \(f[1])")
        }
        let poolStake = try decodeRational(inner[0], label: "relativeStake")
        let relays = try decodeRelays(inner[1])
        return LedgerPeer(accumulatedRelativeStake: accStake, relativeStake: poolStake, relays: relays)
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
        let relayType: UInt
        switch f[0] {
        case .uint(let u): relayType = u
        case .int(let i) where i >= 0: relayType = UInt(i)
        default:
            throw LedgerStateDecodingError.unexpectedFormat(
                "BigLedgerPeerSnapshot: expected uint relay type, got \(f[0])")
        }
        let address = try addressFromPrimitive(f[2], type: relayType)
        return LedgerPeerRelay(address: address, port: port)
    }

    private static func addressFromPrimitive(_ p: Primitive, type relayType: UInt) throws -> String {
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
            let octets: [UInt]
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
                octets = d.map { UInt($0) }
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
        let accNum = UInt(peer.accumulatedRelativeStake.numerator)
        let accDen = UInt(peer.accumulatedRelativeStake.denominator)
        let poolNum = UInt(peer.relativeStake.numerator)
        let poolDen = UInt(peer.relativeStake.denominator)
        let relaysPrim = Primitive.indefiniteList(IndefiniteList(peer.relays.map { relay in
            Primitive.list([
                .uint(0),
                .uint(UInt(relay.port)),
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
