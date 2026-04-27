import Foundation
@testable import SwiftCardanoNetwork

/// In-memory bidirectional `Interface` implementation for governor tests.
///
/// Tests:
/// 1. Hand the emulated interface to an `OutboundGovernor` (or use it
///    standalone with sub-behaviors).
/// 2. Drive the governor with commands; collect what was dispatched via
///    `drainCommands()`.
/// 3. Inject inbound traffic with `emit(_:)` — events flow through the
///    `events` stream the governor consumes.
///
/// `EmulatedInterface` is a class with internal lock-protected state so a
/// single instance can be safely shared between the governor's actor and
/// test code that drives it from outside.
final class EmulatedInterface: Interface, @unchecked Sendable {
    private let lock = NSLock()
    private var _dispatched: [InterfaceCommand] = []
    private let continuation: AsyncStream<InterfaceEvent>.Continuation

    let events: AsyncStream<InterfaceEvent>

    init() {
        var captured: AsyncStream<InterfaceEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    // MARK: - Interface

    func dispatch(_ command: InterfaceCommand) async {
        lock.withLock { _dispatched.append(command) }
    }

    // MARK: - Test API

    /// Inject an inbound event for the consumer of `events` to observe.
    func emit(_ event: InterfaceEvent) {
        continuation.yield(event)
    }

    /// Take and clear every command issued so far.
    func drainCommands() -> [InterfaceCommand] {
        lock.withLock {
            defer { _dispatched.removeAll() }
            return _dispatched
        }
    }

    /// Snapshot of currently-pending commands without clearing them.
    var pendingCommands: [InterfaceCommand] {
        lock.withLock { _dispatched }
    }

    /// Close the event stream — consumers' `for await` loops exit.
    func finish() {
        continuation.finish()
    }
}
