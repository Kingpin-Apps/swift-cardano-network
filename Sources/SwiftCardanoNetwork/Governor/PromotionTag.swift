/// The promotion level of a peer in the outbound governor (§3.11.5).
///
/// The governor tracks four mutually-exclusive sets and moves peers between
/// them on housekeeping ticks based on `PromotionConfig` caps and the peer's
/// connection / error state.
///
/// ```
/// .cold → .warm → .hot
///   ↘    ↗   ↘
///    .banned (terminal — never re-discovered)
/// ```
public enum PromotionTag: Sendable, Equatable, CustomStringConvertible {
    /// Known but no connection attempt is being made.
    case cold
    /// Connected with handshake done; basic protocols (handshake/keepAlive) only.
    case warm
    /// Fully active; all wired mini-protocols may run.
    case hot
    /// Banned — never connected, never re-promoted on rediscovery.
    case banned

    public var description: String {
        switch self {
        case .cold:   return "cold"
        case .warm:   return "warm"
        case .hot:    return "hot"
        case .banned: return "banned"
        }
    }
}
