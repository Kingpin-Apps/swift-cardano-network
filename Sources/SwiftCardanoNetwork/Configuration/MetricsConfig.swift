public struct MetricsConfig: Codable, Sendable {
    /// Whether to emit metrics at all
    public var enabled: Bool = true
    /// Prefix for all metric names
    public var namePrefix: String = "cardano_network"
    /// Extra dimensions added to every metric emission
    public var globalDimensions: [String: String] = [:]

    public init() {}
}
