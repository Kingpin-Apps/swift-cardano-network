/// A unified buffer of governor outputs — interface commands and external
/// events — accumulated by sub-behaviors during a single visitor pass and
/// drained by the `OutboundGovernor` after the pass completes.
///
/// Each visitor receives the queue as `inout` and pushes commands or events
/// onto it; the governor flushes to the `Interface` (commands) and to the
/// public `events` stream (events) once all visitors have run.
///
/// This indirection mirrors `pallas-network2`'s `OutboundQueue<B>` and lets
/// each visitor behave as a pure transformation `(state, queue) -> (state',
/// queue')` without holding a reference to the runtime.
public struct OutboundQueue: Sendable {

    /// Combined ordered output. Commands and events are interleaved in the
    /// order they were pushed.
    public enum Item: Sendable {
        case command(InterfaceCommand)
        case event(GovernorEvent)
    }

    private(set) public var items: [Item] = []

    public init() {}

    public mutating func push(_ command: InterfaceCommand) {
        items.append(.command(command))
    }

    public mutating func push(_ event: GovernorEvent) {
        items.append(.event(event))
    }

    /// Move every accumulated item out of the queue, leaving it empty.
    public mutating func drain() -> [Item] {
        defer { items.removeAll(keepingCapacity: true) }
        return items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
}
