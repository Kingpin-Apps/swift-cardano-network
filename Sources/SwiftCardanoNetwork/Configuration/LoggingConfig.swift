import Logging

public struct LoggingConfig: Codable, Sendable {
    /// Minimum log level emitted by this library.
    public var level: Logger.Level = .info
    /// Label prefix applied to all child loggers.
    public var labelPrefix: String = "cardano-network"
    /// Log output destination.
    ///
    /// Accepted values:
    /// - `"stdout"` — standard output (default)
    /// - `"stderr"` — standard error
    /// - `"system"` — platform-native logging:
    ///   - **macOS / iOS**: Apple Unified Logging (`os.Logger`). Entries appear in
    ///     **Console.app** and are streamable via `log stream --subsystem <prefix>`.
    ///   - **Linux**: POSIX `syslog(3)`. Entries are captured by `systemd-journald`
    ///     and queryable with `journalctl -t <process-name>`.
    ///   - Other platforms: falls back to `"stdout"`.
    /// - Any other string is interpreted as an absolute or relative file-system path;
    ///   the file is created if it does not exist and log lines are appended to it.
    public var destination: String = "stdout"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level       = try c.decodeIfPresent(Logger.Level.self, forKey: .level)       ?? .info
        labelPrefix = try c.decodeIfPresent(String.self,       forKey: .labelPrefix) ?? "cardano-network"
        destination = try c.decodeIfPresent(String.self,       forKey: .destination) ?? "stdout"
    }
}
