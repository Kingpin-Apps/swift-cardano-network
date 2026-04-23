import Foundation
import Logging

/// Creates child `Logger` instances with a consistent label hierarchy.
///
/// By default every logger writes to **standard output** at the `.info` level.
/// Call ``configure(_:)`` once at startup (before creating any connections) to change
/// the level, label prefix, or log destination.
///
/// Because this factory uses ``Logger/init(label:factory:)`` to inject a handler
/// directly into each logger, it does **not** touch the global `LoggingSystem`
/// bootstrap — the application remains free to configure its own log backend
/// independently.
public enum LoggerFactory {
    // All three properties are written once at startup before any concurrent access;
    // nonisolated(unsafe) opts them out of Swift 6 actor-isolation checks.
    nonisolated(unsafe) private static var prefix: String = "cardano-network"
    nonisolated(unsafe) private static var level: Logger.Level = .info
    nonisolated(unsafe) private static var handlerFactory: @Sendable (String) -> any LogHandler =
        { StreamLogHandler.standardOutput(label: $0) }

    // MARK: - Public API

    /// Apply the library's `LoggingConfig`.
    ///
    /// Updates the label prefix, log level, and output destination for every logger
    /// created **after** this call. Previously created `Logger` instances are unaffected.
    public static func configure(_ config: LoggingConfig) {
        prefix = config.labelPrefix
        level = config.level
        handlerFactory = makeHandlerFactory(for: config.destination)
    }

    /// Return a `Logger` labelled `<prefix>.<subsystem>` at the configured level.
    ///
    /// Logs are written to the destination configured via ``configure(_:)``,
    /// defaulting to **standard output** when no configuration has been applied.
    public static func logger(subsystem: String) -> Logger {
        let label = "\(prefix).\(subsystem)"
        var log = Logger(label: label, factory: handlerFactory)
        log.logLevel = level
        return log
    }

    // MARK: - Private

    private static func makeHandlerFactory(
        for destination: String
    ) -> @Sendable (String) -> any LogHandler {
        switch destination.lowercased() {
        case "stderr":
            return { StreamLogHandler.standardError(label: $0) }
        case "stdout":
            return { StreamLogHandler.standardOutput(label: $0) }
        case "system":
            // Route to the platform's native logging facility:
            //   macOS/iOS – Apple Unified Logging (visible in Console.app & `log stream`)
            //   Linux     – POSIX syslog (captured by systemd-journald, queryable via `journalctl`)
            //   other     – falls back to stdout
            #if canImport(Darwin)
                return { OSLogHandler(label: $0) }
            #elseif os(Linux)
                return { SyslogHandler(label: $0) }
            #else
                return { StreamLogHandler.standardOutput(label: $0) }
            #endif
        default:
            // Treat any other value as a file-system path.
            let url = URL(fileURLWithPath: destination)
            return { label in
                (try? FileLogHandler(label: label, fileURL: url))
                    ?? StreamLogHandler.standardOutput(label: label)
            }
        }
    }
}
