import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Version constants

@Suite("Handshake version constants") struct HandshakeVersionConstantsTests {
    @Test func nodeToNodeVersions() {
        #expect(NodeToNodeVersion.v7  == 7)
        #expect(NodeToNodeVersion.v8  == 8)
        #expect(NodeToNodeVersion.v9  == 9)
        #expect(NodeToNodeVersion.v10 == 10)
        #expect(NodeToNodeVersion.v11 == 11)
        #expect(NodeToNodeVersion.v12 == 12)
        #expect(NodeToNodeVersion.v13 == 13)
        #expect(NodeToNodeVersion.v14 == 14)
    }

    @Test func nodeToClientVersions() {
        // Wire values include bit 15 (0x8000 = 32768) per spec §3.1
        #expect(NodeToClientVersion.v9  == 32777)
        #expect(NodeToClientVersion.v14 == 32782)
        #expect(NodeToClientVersion.v15 == 32783)
        #expect(NodeToClientVersion.v16 == 32784)
        #expect(NodeToClientVersion.v17 == 32785)
        #expect(NodeToClientVersion.v18 == 32786)
        #expect(NodeToClientVersion.v19 == 32787)
        #expect(NodeToClientVersion.v20 == 32788)
        #expect(NodeToClientVersion.v21 == 32789)
    }

    @Test func nodeToNodeV15() {
        #expect(NodeToNodeVersion.v15 == 15)
    }

    @Test func conwayVersionsAreHighest() {
        #expect(NodeToNodeVersion.v14   > NodeToNodeVersion.v13)
        #expect(NodeToClientVersion.v16 > NodeToClientVersion.v15)
    }
}

// MARK: - HandshakeState (state machine)

@Suite("HandshakeState") struct HandshakeStateTests {
    @Test func agencyRules() {
        #expect(HandshakeState.start.agency    == .client)
        #expect(HandshakeState.proposed.agency == .server)
        #expect(HandshakeState.accepted.agency == .nobody)
        #expect(HandshakeState.refused.agency  == .nobody)
    }

    @Test func transitionStartToProposed() throws {
        let next = try HandshakeState.start.afterSend(.proposeVersions([:]))
        #expect(next == .proposed)
    }

    @Test func transitionProposedToAccepted() throws {
        let vd = HandshakeVersionData.nodeToClient(networkMagic: 2)
        let next = try HandshakeState.proposed.afterReceive(.acceptVersion(16, vd))
        #expect(next == .accepted)
    }

    @Test func transitionProposedToRefused() throws {
        let next = try HandshakeState.proposed.afterReceive(.refuse(.versionMismatch([])))
        #expect(next == .refused)
    }

    @Test func invalidSendFromProposedThrows() {
        #expect(throws: (any Error).self) {
            _ = try HandshakeState.proposed.afterSend(.proposeVersions([:]))
        }
    }

    @Test func invalidSendFromAcceptedThrows() {
        #expect(throws: (any Error).self) {
            _ = try HandshakeState.accepted.afterSend(.proposeVersions([:]))
        }
    }

    @Test func invalidReceiveFromStartThrows() {
        let vd = HandshakeVersionData.nodeToClient(networkMagic: 1)
        #expect(throws: (any Error).self) {
            _ = try HandshakeState.start.afterReceive(.acceptVersion(9, vd))
        }
    }

    @Test func invalidReceiveFromAcceptedThrows() {
        let vd = HandshakeVersionData.nodeToClient(networkMagic: 1)
        #expect(throws: (any Error).self) {
            _ = try HandshakeState.accepted.afterReceive(.acceptVersion(9, vd))
        }
    }
}

// MARK: - HandshakeCodec (NtN)

@Suite("HandshakeCodec NtN") struct HandshakeCodecNtNTests {
    private let codec = HandshakeCodec(mode: .nodeToNode)
    private let alloc = ByteBufferAllocator()

    private func roundTrip(_ msg: HandshakeMessage) throws -> HandshakeMessage {
        var buf = try codec.encode(msg, allocator: alloc)
        return try codec.decode(&buf)
    }

    @Test func proposeVersionsRoundTrip() throws {
        let versions: [UInt16: HandshakeVersionData] = [
            14: .nodeToNode(networkMagic: 764_824_073, initiatorOnly: false, peerSharing: nil, query: nil),
            13: .nodeToNode(networkMagic: 764_824_073, initiatorOnly: false, peerSharing: nil, query: nil),
        ]
        let decoded = try roundTrip(.proposeVersions(versions))
        guard case .proposeVersions(let dv) = decoded else {
            Issue.record("Expected .proposeVersions, got \(decoded)")
            return
        }
        #expect(dv.count == 2)
        #expect(dv[14] != nil)
        #expect(dv[13] != nil)
    }

    @Test func acceptVersionRoundTrip() throws {
        let vd = HandshakeVersionData.nodeToNode(networkMagic: 764_824_073, initiatorOnly: false, peerSharing: nil, query: nil)
        let decoded = try roundTrip(.acceptVersion(14, vd))
        guard case .acceptVersion(let v, let dvd) = decoded else {
            Issue.record("Expected .acceptVersion, got \(decoded)")
            return
        }
        #expect(v == 14)
        guard case .nodeToNode(let magic, let initOnly, _, _) = dvd else {
            Issue.record("Expected .nodeToNode version data")
            return
        }
        #expect(magic    == 764_824_073)
        #expect(initOnly == false)
    }

    @Test func refuseVersionMismatchRoundTrip() throws {
        let decoded = try roundTrip(.refuse(.versionMismatch([7, 8, 9])))
        guard case .refuse(let reason) = decoded else {
            Issue.record("Expected .refuse"); return
        }
        guard case .versionMismatch(let versions) = reason else {
            Issue.record("Expected .versionMismatch"); return
        }
        #expect(versions.sorted() == [7, 8, 9])
    }

    @Test func refuseHandshakeDecodeErrorRoundTrip() throws {
        let decoded = try roundTrip(.refuse(.handshakeDecodeError(12, "bad cbor")))
        guard case .refuse(let reason) = decoded else {
            Issue.record("Expected .refuse"); return
        }
        guard case .handshakeDecodeError(let v, let msg) = reason else {
            Issue.record("Expected .handshakeDecodeError"); return
        }
        #expect(v   == 12)
        #expect(msg == "bad cbor")
    }

    @Test func refuseRefusedRoundTrip() throws {
        let decoded = try roundTrip(.refuse(.refused(14, "incompatible magic")))
        guard case .refuse(let reason) = decoded else {
            Issue.record("Expected .refuse"); return
        }
        guard case .refused(let v, let msg) = reason else {
            Issue.record("Expected .refused"); return
        }
        #expect(v   == 14)
        #expect(msg == "incompatible magic")
    }

    @Test func proposeVersionsWithInitiatorOnlyFlagRoundTrip() throws {
        let versions: [UInt16: HandshakeVersionData] = [
            14: .nodeToNode(networkMagic: 2, initiatorOnly: true, peerSharing: nil, query: nil),
        ]
        let decoded = try roundTrip(.proposeVersions(versions))
        guard case .proposeVersions(let dv) = decoded,
              case .nodeToNode(_, let flag, _, _) = dv[14] else {
            Issue.record("Unexpected decode result")
            return
        }
        #expect(flag == true)
    }
}

// MARK: - HandshakeCodec (NtC)

@Suite("HandshakeCodec NtC") struct HandshakeCodecNtCTests {
    private let codec = HandshakeCodec(mode: .nodeToClient)
    private let alloc = ByteBufferAllocator()

    private func roundTrip(_ msg: HandshakeMessage) throws -> HandshakeMessage {
        var buf = try codec.encode(msg, allocator: alloc)
        return try codec.decode(&buf)
    }

    @Test func proposeVersionsRoundTrip() throws {
        let versions: [UInt16: HandshakeVersionData] = [
            16: .nodeToClient(networkMagic: 1),
            15: .nodeToClient(networkMagic: 1),
            9:  .nodeToClient(networkMagic: 1),
        ]
        let decoded = try roundTrip(.proposeVersions(versions))
        guard case .proposeVersions(let dv) = decoded else {
            Issue.record("Expected .proposeVersions"); return
        }
        #expect(dv.count == 3)
        #expect(dv[16] != nil)
        #expect(dv[9]  != nil)
    }

    @Test func acceptVersionRoundTrip() throws {
        let vd = HandshakeVersionData.nodeToClient(networkMagic: 764_824_073)
        let decoded = try roundTrip(.acceptVersion(16, vd))
        guard case .acceptVersion(let v, let dvd) = decoded else {
            Issue.record("Expected .acceptVersion"); return
        }
        #expect(v == 16)
        guard case .nodeToClient(let magic, _) = dvd else {
            Issue.record("Expected .nodeToClient version data"); return
        }
        #expect(magic == 764_824_073)
    }

    @Test func acceptVersionWithQueryRoundTrip() throws {
        let vd = HandshakeVersionData.nodeToClient(networkMagic: 764_824_073, query: true)
        let decoded = try roundTrip(.acceptVersion(32784, vd))
        guard case .acceptVersion(_, let dvd) = decoded,
              case .nodeToClient(_, let query) = dvd else {
            Issue.record("Expected .nodeToClient with query"); return
        }
        #expect(query == true)
    }

    @Test func proposeVersionsPreviewMagicRoundTrip() throws {
        let versions: [UInt16: HandshakeVersionData] = [
            16: .nodeToClient(networkMagic: 2),
        ]
        let decoded = try roundTrip(.proposeVersions(versions))
        guard case .proposeVersions(let dv) = decoded,
              case .nodeToClient(let magic, _) = dv[16] else {
            Issue.record("Unexpected decode result"); return
        }
        #expect(magic == 2)
    }

    @Test func refuseVersionMismatchRoundTrip() throws {
        let decoded = try roundTrip(.refuse(.versionMismatch([9, 14, 15, 16])))
        guard case .refuse(let reason) = decoded,
              case .versionMismatch(let versions) = reason else {
            Issue.record("Expected .refuse .versionMismatch"); return
        }
        #expect(versions.sorted() == [9, 14, 15, 16])
    }
}

// MARK: - HandshakeError

@Suite("HandshakeError") struct HandshakeErrorTests {
    @Test func errorCases() {
        let errs: [HandshakeError] = [
            .malformedMessage,
            .malformedVersionData,
            .unknownMessageTag(99),
            .unknownRefuseTag(5),
            .refused(.versionMismatch([])),
            .queryReplyReceived,
        ]
        #expect(errs.count == 6)
    }
}
