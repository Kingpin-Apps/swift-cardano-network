import Testing
import NIOCore
import NIOEmbedded
import Logging
@testable import SwiftCardanoNetwork

// MARK: - Test doubles

private struct MockMessage: Sendable, Equatable {
    let value: UInt8
    static let ping = MockMessage(value: 0)
    static let pong = MockMessage(value: 1)
}

private struct MockCodec: ProtocolCodec, Sendable {
    typealias Message = MockMessage

    func encode(_ message: MockMessage, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        var buf = allocator.buffer(capacity: 1)
        buf.writeInteger(message.value)
        return buf
    }

    func decode(_ buffer: inout ByteBuffer) throws -> MockMessage {
        guard let v = buffer.readInteger(as: UInt8.self) else { throw MockCodecError.truncated }
        return MockMessage(value: v)
    }
}

private enum MockCodecError: Error { case truncated }

private struct MockState: ProtocolState, Sendable {
    let agency: Agency
}

// MARK: - Agency

@Suite("Agency") struct AgencyTests {
    @Test func threeAgencyCases() {
        let cases: [Agency] = [.client, .server, .nobody]
        #expect(cases.count == 3)
    }

    @Test func agencyEquality() {
        #expect(Agency.client == .client)
        #expect(Agency.server == .server)
        #expect(Agency.nobody == .nobody)
        #expect(Agency.client != .server)
    }
}

// MARK: - ProtocolError

@Suite("ProtocolError") struct ProtocolErrorTests {
    @Test func agencyViolationPayload() {
        let err = ProtocolError.agencyViolation(protocol: "test", state: "idle", agency: .server)
        if case .agencyViolation(let proto, let state, let agency) = err {
            #expect(proto  == "test")
            #expect(state  == "idle")
            #expect(agency == .server)
        } else {
            Issue.record("Wrong error case")
        }
    }

    @Test func unexpectedReceivePayload() {
        let err = ProtocolError.unexpectedReceive(protocol: "test", state: "canAwait")
        if case .unexpectedReceive(let proto, let state) = err {
            #expect(proto == "test")
            #expect(state == "canAwait")
        } else {
            Issue.record("Wrong error case")
        }
    }

    @Test func connectionClosedCase() {
        let err = ProtocolError.connectionClosed
        if case .connectionClosed = err { /* pass */ }
        else { Issue.record("Wrong error case") }
    }

    @Test func invalidTransitionPayload() {
        let err = ProtocolError.invalidTransition(protocol: "chainSync", state: "idle", message: "awaitReply")
        if case .invalidTransition(let proto, let state, let msg) = err {
            #expect(proto == "chainSync")
            #expect(state == "idle")
            #expect(msg   == "awaitReply")
        } else {
            Issue.record("Wrong error case")
        }
    }
}

// MARK: - ProtocolDriver

@Suite("ProtocolDriver") @MainActor struct ProtocolDriverTests {
    private let logger = Logger(label: "test.driver")

    /// Build a driver whose initial state has the given agency.
    private func makeDriver(
        agency: Agency,
        stream: AsyncStream<MuxSDU> = AsyncStream { $0.finish() }
    ) -> ProtocolDriver<MockCodec> {
        let channel = EmbeddedChannel()
        return ProtocolDriver(
            channel: channel,
            codec: MockCodec(),
            protocolID: 0,
            initialState: MockState(agency: agency),
            inboundStream: stream,
            protocolName: "mock",
            logger: logger
        )
    }

    // MARK: Agency violation on send

    @Test func sendThrowsWhenServerHasAgency() async throws {
        let driver = makeDriver(agency: .server)
        var threw = false
        do {
            try await driver.send(.ping) { s in s }
        } catch let err as ProtocolError {
            if case .agencyViolation = err { threw = true }
        } catch {}
        #expect(threw, "Expected ProtocolError.agencyViolation")
    }

    @Test func sendThrowsWhenNobodyHasAgency() async throws {
        let driver = makeDriver(agency: .nobody)
        var threw = false
        do {
            try await driver.send(.ping) { s in s }
        } catch let err as ProtocolError {
            if case .agencyViolation = err { threw = true }
        } catch {}
        #expect(threw, "Expected ProtocolError.agencyViolation")
    }

    // MARK: Agency violation on receive

    @Test func receiveThrowsWhenClientHasAgency() async throws {
        let driver = makeDriver(agency: .client)
        var threw = false
        do {
            _ = try await driver.receive { _, s in s }
        } catch let err as ProtocolError {
            if case .unexpectedReceive = err { threw = true }
        } catch {}
        #expect(threw, "Expected ProtocolError.unexpectedReceive")
    }

    @Test func receiveThrowsWhenNobodyHasAgency() async throws {
        let driver = makeDriver(agency: .nobody)
        var threw = false
        do {
            _ = try await driver.receive { _, s in s }
        } catch let err as ProtocolError {
            if case .unexpectedReceive = err { threw = true }
        } catch {}
        #expect(threw, "Expected ProtocolError.unexpectedReceive")
    }

    // MARK: Connection closed

    @Test func receiveThrowsConnectionClosedOnFinishedStream() async throws {
        // Stream is pre-finished (yields nothing then closes).
        let stream = AsyncStream<MuxSDU> { $0.finish() }
        let driver = makeDriver(agency: .server, stream: stream)

        var threw = false
        do {
            _ = try await driver.receive { _, s in s }
        } catch let err as ProtocolError {
            if case .connectionClosed = err { threw = true }
        } catch {}
        #expect(threw, "Expected ProtocolError.connectionClosed")
    }

    // MARK: State is exposed

    @Test func initialStateReflectsConstruction() async {
        let driver = makeDriver(agency: .client)
        let state = await driver.state
        #expect(state.agency == .client)
    }

    // MARK: Send advances state via transition closure

    @Test func sendAdvancesStateViaTransition() async throws {
        // NIOAsyncTestingChannel uses a lock-based event loop, so the write
        // inside ProtocolDriver (an actor) is safe from any thread.
        let channel = NIOAsyncTestingChannel()

        let driver = ProtocolDriver(
            channel: channel,
            codec: MockCodec(),
            protocolID: 0,
            initialState: MockState(agency: .client),
            inboundStream: AsyncStream { $0.finish() },
            protocolName: "mock",
            logger: logger
        )

        try await driver.send(.ping) { _ in MockState(agency: .server) }

        let stateAfterSend = await driver.state
        #expect(stateAfterSend.agency == .server)

        // Drain the buffered MuxSDU then close the channel.
        while (try? await channel.readOutbound(as: MuxSDU.self)) != nil {}
        _ = try? await channel.finish()
    }
}
