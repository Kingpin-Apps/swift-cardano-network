import Foundation
// Needed to resolve `Logger.Level` in the file-private helper above.
import Logging

extension CardanoNetworkConfiguration {
    /// Load configuration from a JSON file at `path`.
    public static func load(fromFile path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Overlay environment variables on top of an existing configuration.
    ///
    /// Supported variables:
    /// - `CARDANO_NETWORK_SOCKET_PATH`   → `connection.socketPath`
    /// - `CARDANO_NETWORK_HOST`          → `connection.host`
    /// - `CARDANO_NETWORK_PORT`          → `connection.port`
    /// - `CARDANO_NETWORK_MAGIC`         → `connection.networkMagic`
    /// - `CARDANO_NETWORK_CONNECT_TIMEOUT` → `connection.connectTimeoutSeconds`
    /// - `CARDANO_NETWORK_LOG_LEVEL`     → `logging.level`
    /// - `CARDANO_NETWORK_LOG_DEST`       → `logging.destination` (`stdout`, `stderr`, `system`, or a file path)
    /// - `CARDANO_NETWORK_METRICS_ENABLED` → `metrics.enabled`
    public func mergedWithEnvironment() -> Self {
        var c = self
        let env = ProcessInfo.processInfo.environment

        if let v = env["CARDANO_NETWORK_SOCKET_PATH"] { c.connection.socketPath = v }
        if let v = env["CARDANO_NETWORK_HOST"] { c.connection.host = v }
        if let v = env["CARDANO_NETWORK_PORT"], let port = Int(v) { c.connection.port = port }
        if let v = env["CARDANO_NETWORK_MAGIC"], let magic = UInt32(v) {
            c.connection.networkMagic = magic
        }
        if let v = env["CARDANO_NETWORK_CONNECT_TIMEOUT"], let t = Double(v) {
            c.connection.connectTimeoutSeconds = t
        }
        if let v = env["CARDANO_NETWORK_LOG_LEVEL"] {
            c.logging.level = Self.parseLogLevel(v) ?? c.logging.level
        }
        if let v = env["CARDANO_NETWORK_LOG_DEST"] { c.logging.destination = v }
        if let v = env["CARDANO_NETWORK_METRICS_ENABLED"] {
            c.metrics.enabled = v.lowercased() == "true"
        }

        return c
    }

    /// Load from a JSON file, then overlay environment variables.
    public static func load(fromFile path: String, mergedWithEnvironment: Bool = true) throws
        -> Self
    {
        let base = try load(fromFile: path)
        return mergedWithEnvironment ? base.mergedWithEnvironment() : base
    }

    /// Build entirely from environment variables, using defaults where unset.
    public static func loadFromEnvironment() -> Self {
        Self().mergedWithEnvironment()
    }

    private static func parseLogLevel(_ string: String) -> Logging.Logger.Level? {
        switch string.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return nil
        }
    }
}
