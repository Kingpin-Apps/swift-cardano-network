/// Root configuration struct for all CardanoNetwork tunables.
/// Codable so it can be loaded from JSON/YAML or constructed programmatically.
public struct CardanoNetworkConfiguration: Codable, Sendable {
    public var connection: ConnectionConfig = .init()
    public var logging: LoggingConfig = .init()
    public var metrics: MetricsConfig = .init()
    public var `protocol`: ProtocolConfig = .init()

    public init() {}
}

// MARK: - Well-known network presets

extension CardanoNetworkConfiguration {
    public static var mainnet: Self {
        var config = Self()
        config.connection.networkMagic = 764_824_073
        config.connection.host = "relays-new.cardano-mainnet.iohk.io"
        config.connection.port = 3001
        return config
    }

    public static var preview: Self {
        var config = Self()
        config.connection.networkMagic = 2
        config.connection.host = "preview-node.play.dev.cardano.org"
        config.connection.port = 3001
        return config
    }

    public static var preprod: Self {
        var config = Self()
        config.connection.networkMagic = 1
        config.connection.host = "preprod-node.play.dev.cardano.org"
        config.connection.port = 3001
        return config
    }
}
