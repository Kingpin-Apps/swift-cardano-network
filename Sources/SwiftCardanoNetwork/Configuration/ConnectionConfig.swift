import Logging

public struct ConnectionConfig: Codable, Sendable {
    /// Unix socket path for NtC connections, e.g. "/ipc/node.socket"
    public var socketPath: String?
    /// Host for NtN TCP connections
    public var host: String = "localhost"
    /// Port for NtN TCP connections
    public var port: Int = 3001
    /// Cardano network magic (mainnet: 764824073, preview: 2, preprod: 1)
    public var networkMagic: UInt32 = 764824073
    /// Seconds to wait for a connection before timing out
    public var connectTimeoutSeconds: Double = 10.0
    /// Maximum reconnect attempts; nil = unlimited
    public var maxReconnectAttempts: Int? = nil
    /// Base delay for exponential backoff on reconnect
    public var reconnectBaseDelaySeconds: Double = 1.0
    /// Cap for reconnect backoff delay
    public var reconnectMaxDelaySeconds: Double = 60.0

    public init() {}
}
