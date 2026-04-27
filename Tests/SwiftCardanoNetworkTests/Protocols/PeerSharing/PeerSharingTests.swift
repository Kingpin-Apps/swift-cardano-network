import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()
private let codec = PeerSharingCodec()

private func roundTrip(_ msg: PeerSharingMessage) throws -> PeerSharingMessage {
    var buf = try codec.encode(msg, allocator: alloc)
    return try codec.decode(&buf)
}

// MARK: - PeerAddress

@Suite("PeerAddress") struct PeerAddressTests {

    @Test func ipv4Equality() {
        let a = PeerAddress.ipv4(addr: 0x7F00_0001, port: 3001)
        let b = PeerAddress.ipv4(addr: 0x7F00_0001, port: 3001)
        let c = PeerAddress.ipv4(addr: 0x7F00_0001, port: 3002)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func ipv6Equality() {
        let a = PeerAddress.ipv6(addr: (1, 2, 3, 4), port: 3001)
        let b = PeerAddress.ipv6(addr: (1, 2, 3, 4), port: 3001)
        let c = PeerAddress.ipv6(addr: (1, 2, 3, 5), port: 3001)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func ipv4VsIpv6Inequality() {
        let v4 = PeerAddress.ipv4(addr: 0, port: 3001)
        let v6 = PeerAddress.ipv6(addr: (0, 0, 0, 0), port: 3001)
        #expect(v4 != v6)
    }

    @Test func ipv4HostString() {
        let p = PeerAddress.ipv4(addr: 0x7F00_0001, port: 3001)
        #expect(p.host == "127.0.0.1")
        #expect(p.port == 3001)
    }

    @Test func ipv4HostStringEdge() {
        let p = PeerAddress.ipv4(addr: 0xC0A8_0101, port: 80)
        #expect(p.host == "192.168.1.1")
    }

    @Test func ipv6HostString() {
        // 2001:db8:: with last word 0x0000_0001
        let p = PeerAddress.ipv6(
            addr: (0x2001_0DB8, 0, 0, 0x0000_0001),
            port: 3001
        )
        #expect(p.host == "2001:db8:0:0:0:0:0:1")
        #expect(p.port == 3001)
    }

    @Test func hashableWorksInSet() {
        var set = Set<PeerAddress>()
        set.insert(.ipv4(addr: 1, port: 1))
        set.insert(.ipv4(addr: 1, port: 1))
        set.insert(.ipv4(addr: 1, port: 2))
        set.insert(.ipv6(addr: (0, 0, 0, 1), port: 1))
        #expect(set.count == 3)
    }
}

// MARK: - PeerSharingState

@Suite("PeerSharingState") struct PeerSharingStateTests {

    @Test func agencyRules() {
        #expect(PeerSharingState.idle.agency == .client)
        #expect(PeerSharingState.busy.agency == .server)
        #expect(PeerSharingState.done.agency == .nobody)
    }

    @Test func descriptions() {
        #expect(PeerSharingState.idle.description == "idle")
        #expect(PeerSharingState.busy.description == "busy")
        #expect(PeerSharingState.done.description == "done")
    }

    // MARK: Send transitions

    @Test func idleShareRequestToBusy() throws {
        let next = try PeerSharingState.idle.afterSend(.shareRequest(amount: 5))
        #expect(next == .busy)
    }

    @Test func idleDoneToDone() throws {
        let next = try PeerSharingState.idle.afterSend(.done)
        #expect(next == .done)
    }

    @Test func amountZeroIsValid() throws {
        let next = try PeerSharingState.idle.afterSend(.shareRequest(amount: 0))
        #expect(next == .busy)
    }

    @Test func amountMaxIsValid() throws {
        let next = try PeerSharingState.idle.afterSend(.shareRequest(amount: UInt8.max))
        #expect(next == .busy)
    }

    // MARK: Invalid send transitions

    @Test func invalidSendShareRequestFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.busy.afterSend(.shareRequest(amount: 1))
        }
    }

    @Test func invalidSendSharePeersFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.idle.afterSend(.sharePeers([]))
        }
    }

    @Test func invalidSendDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.busy.afterSend(.done)
        }
    }

    @Test func invalidSendFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.done.afterSend(.shareRequest(amount: 1))
        }
    }

    // MARK: Receive transitions

    @Test func busySharePeersToIdle() throws {
        let next = try PeerSharingState.busy.afterReceive(.sharePeers([]))
        #expect(next == .idle)
    }

    @Test func busySharePeersWithDataToIdle() throws {
        let peers: [PeerAddress] = [.ipv4(addr: 0x7F00_0001, port: 3001)]
        let next = try PeerSharingState.busy.afterReceive(.sharePeers(peers))
        #expect(next == .idle)
    }

    // MARK: Invalid receive transitions

    @Test func invalidReceiveFromIdleThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.idle.afterReceive(.sharePeers([]))
        }
    }

    @Test func invalidReceiveFromDoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.done.afterReceive(.sharePeers([]))
        }
    }

    @Test func invalidReceiveShareRequestFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.busy.afterReceive(.shareRequest(amount: 1))
        }
    }

    @Test func invalidReceiveDoneFromBusyThrows() {
        #expect(throws: (any Error).self) {
            _ = try PeerSharingState.busy.afterReceive(.done)
        }
    }

    // MARK: Full sequence

    @Test func fullRequestSequence() throws {
        var state = PeerSharingState.idle
        state = try state.afterSend(.shareRequest(amount: 3))
        #expect(state == .busy)
        state = try state.afterReceive(.sharePeers([
            .ipv4(addr: 0x0A00_0001, port: 3001),
            .ipv4(addr: 0x0A00_0002, port: 3001),
        ]))
        #expect(state == .idle)
        state = try state.afterSend(.done)
        #expect(state == .done)
    }
}

// MARK: - PeerSharingCodec

@Suite("PeerSharingCodec") struct PeerSharingCodecTests {

    // MARK: Round-trips

    @Test func shareRequestRoundTrip() throws {
        let decoded = try roundTrip(.shareRequest(amount: 5))
        guard case .shareRequest(let amount) = decoded else {
            Issue.record("Expected .shareRequest"); return
        }
        #expect(amount == 5)
    }

    @Test func shareRequestZeroRoundTrip() throws {
        let decoded = try roundTrip(.shareRequest(amount: 0))
        guard case .shareRequest(let amount) = decoded else {
            Issue.record("Expected .shareRequest"); return
        }
        #expect(amount == 0)
    }

    @Test func shareRequestMaxRoundTrip() throws {
        let decoded = try roundTrip(.shareRequest(amount: UInt8.max))
        guard case .shareRequest(let amount) = decoded else {
            Issue.record("Expected .shareRequest"); return
        }
        #expect(amount == 255)
    }

    @Test func emptySharePeersRoundTrip() throws {
        let decoded = try roundTrip(.sharePeers([]))
        guard case .sharePeers(let peers) = decoded else {
            Issue.record("Expected .sharePeers"); return
        }
        #expect(peers.isEmpty)
    }

    @Test func ipv4SharePeersRoundTrip() throws {
        let original: [PeerAddress] = [
            .ipv4(addr: 0x7F00_0001, port: 3001),
            .ipv4(addr: 0xC0A8_0101, port: 80),
        ]
        let decoded = try roundTrip(.sharePeers(original))
        guard case .sharePeers(let peers) = decoded else {
            Issue.record("Expected .sharePeers"); return
        }
        #expect(peers == original)
    }

    @Test func ipv6SharePeersRoundTrip() throws {
        let original: [PeerAddress] = [
            .ipv6(addr: (0x2001_0DB8, 0, 0, 1), port: 3001),
        ]
        let decoded = try roundTrip(.sharePeers(original))
        guard case .sharePeers(let peers) = decoded else {
            Issue.record("Expected .sharePeers"); return
        }
        #expect(peers == original)
    }

    @Test func mixedSharePeersRoundTrip() throws {
        let original: [PeerAddress] = [
            .ipv4(addr: 0x7F00_0001, port: 3001),
            .ipv6(addr: (0xFE80_0000, 0, 0, 0x0000_0001), port: 3001),
            .ipv4(addr: 0x0A00_0001, port: 65_535),
        ]
        let decoded = try roundTrip(.sharePeers(original))
        guard case .sharePeers(let peers) = decoded else {
            Issue.record("Expected .sharePeers"); return
        }
        #expect(peers == original)
    }

    @Test func doneRoundTrip() throws {
        let decoded = try roundTrip(.done)
        guard case .done = decoded else {
            Issue.record("Expected .done"); return
        }
    }

    // MARK: Byte-level encoding

    @Test func shareRequestEncodesCorrectly() throws {
        let buf = try codec.encode(.shareRequest(amount: 7), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [0, 7] = 0x82, 0x00, 0x07
        #expect(bytes == [0x82, 0x00, 0x07])
    }

    @Test func emptySharePeersEncodesCorrectly() throws {
        let buf = try codec.encode(.sharePeers([]), allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [1, []] = 0x82, 0x01, 0x80
        #expect(bytes == [0x82, 0x01, 0x80])
    }

    @Test func doneEncodesCorrectly() throws {
        let buf = try codec.encode(.done, allocator: alloc)
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // [2] = 0x81, 0x02
        #expect(bytes == [0x81, 0x02])
    }

    @Test func ipv4PeerEncodesCorrectly() throws {
        // [1, [[0, 0xC0A80101, 3001]]]
        let buf = try codec.encode(
            .sharePeers([.ipv4(addr: 0xC0A8_0101, port: 3001)]),
            allocator: alloc
        )
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes)!
        // 0x82                      ; outer array length 2
        // 0x01                      ; tag = sharePeers
        // 0x81                      ; inner array length 1 (one peer)
        // 0x83                      ; peer-array length 3
        // 0x00                      ; ipv4 tag
        // 0x1A 0xC0 0xA8 0x01 0x01  ; uint32 = 0xC0A80101
        // 0x19 0x0B 0xB9            ; uint16 = 3001
        #expect(bytes == [
            0x82, 0x01, 0x81, 0x83, 0x00,
            0x1A, 0xC0, 0xA8, 0x01, 0x01,
            0x19, 0x0B, 0xB9,
        ])
    }

    // MARK: Indefinite-length peer list (cardano-node wire form)

    @Test func indefiniteLengthSharePeersDecodes() throws {
        // Real cardano-node encodes `peerAddresses = [* peerAddress]` as an
        // indefinite-length CBOR array (`9F ... FF`). The codec must accept
        // that form even though we always emit definite-length on the wire.
        //
        // Wire layout:
        //   0x82                      ; outer array length 2
        //   0x01                      ; tag = sharePeers
        //   0x9F                      ; indefinite-length array start
        //     0x83 0x00 0x1A 7F 00 00 01 0x19 0x0B 0xB9   ; ipv4 127.0.0.1:3001
        //     0x83 0x00 0x1A C0 A8 01 01 0x19 0x0B 0xB9   ; ipv4 192.168.1.1:3001
        //   0xFF                      ; break
        var buf = alloc.buffer(capacity: 32)
        buf.writeBytes([
            0x82, 0x01, 0x9F,
                0x83, 0x00, 0x1A, 0x7F, 0x00, 0x00, 0x01, 0x19, 0x0B, 0xB9,
                0x83, 0x00, 0x1A, 0xC0, 0xA8, 0x01, 0x01, 0x19, 0x0B, 0xB9,
            0xFF,
        ])
        let decoded = try codec.decode(&buf)
        guard case .sharePeers(let peers) = decoded else {
            Issue.record("Expected .sharePeers, got \(decoded)"); return
        }
        #expect(peers.count == 2)
        #expect(peers[0] == .ipv4(addr: 0x7F00_0001, port: 3001))
        #expect(peers[1] == .ipv4(addr: 0xC0A8_0101, port: 3001))
        // Buffer should be fully consumed (break byte read).
        #expect(buf.readableBytes == 0)
    }

    @Test func indefiniteLengthEmptySharePeersDecodes() throws {
        // 0x82 0x01 0x9F 0xFF — sharePeers with an empty indefinite-length list
        var buf = alloc.buffer(capacity: 4)
        buf.writeBytes([0x82, 0x01, 0x9F, 0xFF])
        let decoded = try codec.decode(&buf)
        guard case .sharePeers(let peers) = decoded else {
            Issue.record("Expected .sharePeers, got \(decoded)"); return
        }
        #expect(peers.isEmpty)
    }

    // MARK: Error cases

    @Test func unknownTagThrows() {
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x81, 0x18, 0x63])  // [99]
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }

    @Test func wrongArrayLengthForDoneThrows() {
        var buf = alloc.buffer(capacity: 3)
        buf.writeBytes([0x82, 0x02, 0x00])  // [2, 0]
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }

    @Test func wrongArrayLengthForShareRequestThrows() {
        var buf = alloc.buffer(capacity: 2)
        buf.writeBytes([0x81, 0x00])  // [0] without amount
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }

    @Test func unknownAddressTagThrows() {
        // [1, [[2, 0, 0]]] — peer address tag 2 is invalid
        var buf = alloc.buffer(capacity: 6)
        buf.writeBytes([0x82, 0x01, 0x81, 0x83, 0x02, 0x00])
        // append two more zeros to satisfy a 3-array but the tag itself fails
        buf.writeBytes([0x00])
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }

    @Test func portOverflowThrows() {
        // [0, 65536] — amount is fine but use a value that overflows UInt8
        // for shareRequest:  0x82 0x00 0x19 0x01 0x00  -> 256 > UInt8.max
        var buf = alloc.buffer(capacity: 5)
        buf.writeBytes([0x82, 0x00, 0x19, 0x01, 0x00])
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }

    @Test func ipv4WrongInnerArrayLengthThrows() {
        // [1, [[0, addr]]] — missing port: peer array length is 2 not 3
        var buf = alloc.buffer(capacity: 8)
        buf.writeBytes([
            0x82, 0x01, 0x81,
            0x82, 0x00,                  // peer array length 2 (should be 3)
            0x1A, 0x7F, 0x00, 0x00, 0x01,
        ])
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }

    @Test func emptyBufferThrows() {
        var buf = alloc.buffer(capacity: 0)
        #expect(throws: (any Error).self) { _ = try codec.decode(&buf) }
    }
}

// MARK: - PeerSharingClient initialiser gating

@Suite("PeerSharingClient.init") struct PeerSharingClientInitTests {

    @Test func rejectsLowVersion() {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let demux = DemuxHandler(logger: Logger(label: "test"))

        let neg = NegotiatedVersion(
            version: NodeToNodeVersion.v13,  // below 14
            versionData: .nodeToNode(
                networkMagic: 1, initiatorOnly: false,
                peerSharing: 1, query: false
            )
        )
        #expect(throws: PeerSharingError.self) {
            _ = try PeerSharingClient(
                channel: channel, demux: demux, negotiatedVersion: neg
            )
        }
    }

    @Test func rejectsDisabledFlag() {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let demux = DemuxHandler(logger: Logger(label: "test"))

        let neg = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(
                networkMagic: 1, initiatorOnly: false,
                peerSharing: 0,  // disabled
                query: false
            )
        )
        #expect(throws: PeerSharingError.self) {
            _ = try PeerSharingClient(
                channel: channel, demux: demux, negotiatedVersion: neg
            )
        }
    }

    @Test func rejectsMissingFlag() {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let demux = DemuxHandler(logger: Logger(label: "test"))

        let neg = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(
                networkMagic: 1, initiatorOnly: false,
                peerSharing: nil,
                query: false
            )
        )
        #expect(throws: PeerSharingError.self) {
            _ = try PeerSharingClient(
                channel: channel, demux: demux, negotiatedVersion: neg
            )
        }
    }

    @Test func rejectsNtcVersionData() {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let demux = DemuxHandler(logger: Logger(label: "test"))

        let neg = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToClient(networkMagic: 1)
        )
        #expect(throws: PeerSharingError.self) {
            _ = try PeerSharingClient(
                channel: channel, demux: demux, negotiatedVersion: neg
            )
        }
    }

    @Test func acceptsEnabledFlagAtV14() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let demux = DemuxHandler(logger: Logger(label: "test"))

        let neg = NegotiatedVersion(
            version: NodeToNodeVersion.v14,
            versionData: .nodeToNode(
                networkMagic: 1, initiatorOnly: false,
                peerSharing: 1,
                query: false
            )
        )
        _ = try PeerSharingClient(
            channel: channel, demux: demux, negotiatedVersion: neg
        )
    }
}

// MARK: - PeerSharingError

@Suite("PeerSharingError") struct PeerSharingErrorTests {

    @Test func tooManyPeersCarriesValues() {
        let err = PeerSharingError.tooManyPeers(requested: 5, received: 7)
        guard case .tooManyPeers(let req, let recv) = err else {
            Issue.record("Expected .tooManyPeers"); return
        }
        #expect(req == 5)
        #expect(recv == 7)
    }

    @Test func unsupportedCarriesVersion() {
        let err = PeerSharingError.unsupported(version: 13, peerSharingFlag: 1)
        guard case .unsupported(let v, let f) = err else {
            Issue.record("Expected .unsupported"); return
        }
        #expect(v == 13)
        #expect(f == 1)
    }
}
