/// A single event produced by the ChainSync `follow` stream.
public enum ChainEvent: Sendable {
    /// The chain has advanced: `block` contains the new block (NtC) or header (NtN).
    case rollForward(block: RawBlock, tip: Tip)
    /// The chain has rolled back to `point`.
    case rollBackward(to: Point, tip: Tip)
}

extension ChainEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .rollForward(let b, let t):
            return "rollForward(era:\(b.era), tip:\(t.point), blockNo:\(t.blockNo))"
        case .rollBackward(let p, let t):
            return "rollBackward(to:\(p), tip:\(t.point))"
        }
    }
}
