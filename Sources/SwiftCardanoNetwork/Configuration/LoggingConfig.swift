import Logging

public struct LoggingConfig: Codable, Sendable {
    /// Minimum log level emitted by this library
    public var level: Logger.Level = .info
    /// Label prefix applied to all child loggers
    public var labelPrefix: String = "cardano-network"

    public init() {}
}
