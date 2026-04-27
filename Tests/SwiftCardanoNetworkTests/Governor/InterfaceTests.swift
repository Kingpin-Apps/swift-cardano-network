import Testing

@testable import SwiftCardanoNetwork

// MARK: - EmulatedInterface

@Suite("EmulatedInterface") struct EmulatedInterfaceTests {

    @Test func startsEmpty() {
        let i = EmulatedInterface()
        #expect(i.pendingCommands.isEmpty)
    }

    @Test func dispatchRecordsCommand() async {
        let i = EmulatedInterface()
        let pid = PeerID(host: "1.2.3.4", port: 3001)
        await i.dispatch(.connect(pid))
        await i.dispatch(.disconnect(pid))
        #expect(i.pendingCommands.count == 2)
    }

    @Test func drainEmptiesAndReturnsAll() async {
        let i = EmulatedInterface()
        let pid = PeerID(host: "1.2.3.4", port: 3001)
        await i.dispatch(.connect(pid))
        await i.dispatch(.disconnect(pid))
        let cmds = i.drainCommands()
        #expect(cmds.count == 2)
        #expect(i.pendingCommands.isEmpty)
    }

    @Test func emitDeliversThroughEvents() async {
        let i = EmulatedInterface()
        let pid = PeerID(host: "1.2.3.4", port: 3001)

        // Subscribe BEFORE emitting so the continuation captures.
        let consumer = Task<InterfaceEvent?, Never> {
            var iter = i.events.makeAsyncIterator()
            return await iter.next()
        }
        // Tiny yield so consumer subscribes first.
        await Task.yield()

        i.emit(.connected(pid))

        let event = await consumer.value
        guard case .connected(let p) = event else {
            Issue.record("expected .connected, got \(String(describing: event))"); return
        }
        #expect(p == pid)
    }

    @Test func finishClosesEventStream() async {
        let i = EmulatedInterface()

        let collected = Task<[InterfaceEvent], Never> {
            var out: [InterfaceEvent] = []
            for await e in i.events { out.append(e) }
            return out
        }
        await Task.yield()

        let pid = PeerID(host: "1.2.3.4", port: 3001)
        i.emit(.connected(pid))
        i.emit(.disconnected(pid))
        i.finish()

        let events = await collected.value
        #expect(events.count == 2)
    }
}

// MARK: - InterfaceEvent

@Suite("InterfaceEvent") struct InterfaceEventTests {

    @Test func sendableShape() {
        let pid = PeerID(host: "1.2.3.4", port: 3001)
        let _: InterfaceEvent = .connected(pid)
        let _: InterfaceEvent = .disconnected(pid)
        let _: InterfaceEvent = .messageReceived(pid, .keepAlive(.done))
    }
}
