import Logging

/// Creates child `Logger` instances with a consistent label hierarchy.
/// Call `configure(_:)` once at startup before making any connections.
public enum LoggerFactory {
    // Written once at startup before any concurrent access; safe to mark nonisolated(unsafe).
    nonisolated(unsafe) private static var prefix: String = "cardano-network"
    nonisolated(unsafe) private static var level: Logger.Level = .info

    /// Apply the library's `LoggingConfig`. Must be called before creating any connections.
    public static func configure(_ config: LoggingConfig) {
        prefix = config.labelPrefix
        level = config.level
    }

    /// Return a `Logger` labelled `<prefix>.<subsystem>` at the configured level.
    public static func logger(subsystem: String) -> Logger {
        var log = Logger(label: "\(prefix).\(subsystem)")
        log.logLevel = level
        return log
    }
}
