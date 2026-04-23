import Logging

// MARK: - Apple Unified Logging (macOS / iOS / tvOS / watchOS)

#if canImport(Darwin)
    import os

    /// A ``LogHandler`` that routes messages into the Apple Unified Logging System.
    ///
    /// Log entries are:
    /// - Visible in **Console.app** — filter by subsystem to narrow results.
    /// - Streamable via `log stream --subsystem <prefix> --level debug` in Terminal.
    /// - Stored in the system log archive and queryable with `log show`.
    ///
    /// The label `"<prefix>.<subsystem>"` produced by ``LoggerFactory`` is split on the
    /// first `.` to derive the OSLog identifiers:
    /// - **subsystem**: everything before the first dot, e.g. `"cardano-network"`
    /// - **category**: everything after the first dot, e.g. `"transport"`
    ///
    /// Swift log levels map to OSLog types as follows:
    ///
    /// | swift-log | OSLogType  |
    /// |-----------|------------|
    /// | trace / debug | `.debug`   |
    /// | info      | `.info`    |
    /// | notice    | `.default` |
    /// | warning / error | `.error` |
    /// | critical  | `.fault`   |
    public struct OSLogHandler: LogHandler {
        public var metadata: Logging.Logger.Metadata = [:]
        public var logLevel: Logging.Logger.Level = .info
        public var metadataProvider: Logging.Logger.MetadataProvider?

        private let osLogger: os.Logger

        /// Create a handler backed by an `os.Logger` derived from `label`.
        public init(label: String) {
            if let dot = label.firstIndex(of: ".") {
                let subsystem = String(label[label.startIndex..<dot])
                let category = String(label[label.index(after: dot)...])
                self.osLogger = os.Logger(subsystem: subsystem, category: category)
            } else {
                self.osLogger = os.Logger(subsystem: label, category: "default")
            }
        }

        public func log(event: LogEvent) {
            let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
            let suffix = merged.isEmpty ? "" : " \(merged)"
            let full = "\(event.message)\(suffix)"

            // Messages must be marked `.public` so they are not redacted in Console.app.
            switch event.level {
            case .trace, .debug:
                osLogger.log(level: .debug, "\(full, privacy: .public)")
            case .info:
                osLogger.log(level: .info, "\(full, privacy: .public)")
            case .notice:
                osLogger.log(level: .default, "\(full, privacy: .public)")
            case .warning, .error:
                osLogger.log(level: .error, "\(full, privacy: .public)")
            case .critical:
                osLogger.log(level: .fault, "\(full, privacy: .public)")
            }
        }

        public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
    }

#endif  // canImport(Darwin)

// MARK: - POSIX syslog (Linux / systemd)

#if os(Linux)
    import Glibc

    /// A ``LogHandler`` that routes messages to the POSIX `syslog` facility.
    ///
    /// On systems running **systemd**, `systemd-journald` captures syslog entries and
    /// makes them queryable via:
    ///
    /// ```
    /// journalctl -t <process-name>          # filter by process
    /// journalctl -p debug                   # filter by priority
    /// journalctl -f                         # follow in real time
    /// ```
    ///
    /// The IDENTIFIER shown in the journal is the process name unless you call
    /// `openlog(3)` yourself before creating the first logger.
    ///
    /// Swift log levels map to syslog priorities as follows:
    ///
    /// | swift-log       | syslog priority |
    /// |-----------------|-----------------|
    /// | trace / debug   | `LOG_DEBUG`     |
    /// | info            | `LOG_INFO`      |
    /// | notice          | `LOG_NOTICE`    |
    /// | warning         | `LOG_WARNING`   |
    /// | error           | `LOG_ERR`       |
    /// | critical        | `LOG_CRIT`      |
    public struct SyslogHandler: LogHandler, @unchecked Sendable {
        public var metadata: Logger.Metadata = [:]
        public var logLevel: Logger.Level = .info
        public var metadataProvider: Logger.MetadataProvider?

        private let label: String

        public init(label: String) {
            self.label = label
        }

        public func log(event: LogEvent) {
            let priority = syslogPriority(for: event.level)
            let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
            var msg = "[\(label)] \(event.message)"
            if !merged.isEmpty { msg += " \(merged)" }
            // Use withCString to avoid format-string injection with user-supplied content.
            msg.withCString { ptr in syslog(priority, "%s", ptr) }
        }

        public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        private func syslogPriority(for level: Logger.Level) -> Int32 {
            switch level {
            case .trace, .debug: return LOG_DEBUG
            case .info: return LOG_INFO
            case .notice: return LOG_NOTICE
            case .warning: return LOG_WARNING
            case .error: return LOG_ERR
            case .critical: return LOG_CRIT
            }
        }
    }

#endif  // os(Linux)
