import Testing
import Foundation
@testable import SwiftCardanoNetwork

// MARK: - ConnectionConfig

@Suite("ConnectionConfig") struct ConnectionConfigTests {
    @Test func defaults() {
        let c = ConnectionConfig()
        #expect(c.host == "localhost")
        #expect(c.port == 3001)
        #expect(c.networkMagic == 764_824_073)
        #expect(c.socketPath == nil)
        #expect(c.connectTimeoutSeconds == 10.0)
        #expect(c.maxReconnectAttempts == nil)
        #expect(c.reconnectBaseDelaySeconds == 1.0)
        #expect(c.reconnectMaxDelaySeconds == 60.0)
    }

    @Test func codableRoundTrip() throws {
        var c = ConnectionConfig()
        c.host = "relay.example.com"
        c.port = 4321
        c.networkMagic = 2
        c.socketPath = "/ipc/node.socket"

        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

        #expect(decoded.host == c.host)
        #expect(decoded.port == c.port)
        #expect(decoded.networkMagic == c.networkMagic)
        #expect(decoded.socketPath == c.socketPath)
    }
}

// MARK: - LoggingConfig

@Suite("LoggingConfig") struct LoggingConfigTests {
    @Test func defaults() {
        let c = LoggingConfig()
        #expect(c.level == .info)
        #expect(c.labelPrefix == "cardano-network")
    }

    @Test func codableRoundTrip() throws {
        var c = LoggingConfig()
        c.level = .debug
        c.labelPrefix = "my-app"

        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(LoggingConfig.self, from: data)
        #expect(decoded.level == c.level)
        #expect(decoded.labelPrefix == c.labelPrefix)
    }
}

// MARK: - MetricsConfig

@Suite("MetricsConfig") struct MetricsConfigTests {
    @Test func defaults() {
        let c = MetricsConfig()
        #expect(c.enabled == true)
        #expect(c.namePrefix == "cardano_network")
        #expect(c.globalDimensions.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        var c = MetricsConfig()
        c.enabled = false
        c.namePrefix = "my_prefix"
        c.globalDimensions = ["env": "prod"]

        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(MetricsConfig.self, from: data)
        #expect(decoded.enabled == false)
        #expect(decoded.namePrefix == "my_prefix")
        #expect(decoded.globalDimensions["env"] == "prod")
    }
}

// MARK: - ProtocolConfig

@Suite("ProtocolConfig") struct ProtocolConfigTests {
    @Test func defaults() {
        let c = ProtocolConfig()
        #expect(c.ntnVersions.first == 14)  // highest supported NtN version (Conway)
        #expect(c.ntcVersions.first == NodeToClientVersion.v23)  // 32791 = highest known NtC
        #expect(c.ntnVersions.last == 7)
        #expect(c.ntcVersions.last == NodeToClientVersion.v9)   // 32777 = oldest known NtC
        #expect(c.ntnMaxSDUSize == 12_288)
        #expect(c.ntcMaxSDUSize == 12_288)
        #expect(c.keepAliveIntervalSeconds == 60.0)
        #expect(c.keepAliveTimeoutSeconds == 10.0)
    }

    @Test func ntnVersionsAreDescending() {
        let c = ProtocolConfig()
        for i in 0..<(c.ntnVersions.count - 1) {
            #expect(c.ntnVersions[i] > c.ntnVersions[i + 1])
        }
    }

    @Test func ntcVersionsAreDescending() {
        let c = ProtocolConfig()
        for i in 0..<(c.ntcVersions.count - 1) {
            #expect(c.ntcVersions[i] > c.ntcVersions[i + 1])
        }
    }
}

// MARK: - CardanoNetworkConfiguration

@Suite("CardanoNetworkConfiguration") struct CardanoNetworkConfigurationTests {
    @Test func mainnetPreset() {
        let c = CardanoNetworkConfiguration.mainnet
        #expect(c.connection.networkMagic == 764_824_073)
        #expect(c.connection.port == 3001)
        #expect(!c.connection.host.isEmpty)
    }

    @Test func previewPreset() {
        let c = CardanoNetworkConfiguration.preview
        #expect(c.connection.networkMagic == 2)
        #expect(c.connection.port == 3001)
    }

    @Test func preprodPreset() {
        let c = CardanoNetworkConfiguration.preprod
        #expect(c.connection.networkMagic == 1)
        #expect(c.connection.port == 3001)
    }

    @Test func presetsHaveDistinctMagics() {
        let mainnet = CardanoNetworkConfiguration.mainnet
        let preview = CardanoNetworkConfiguration.preview
        let preprod = CardanoNetworkConfiguration.preprod
        #expect(mainnet.connection.networkMagic != preview.connection.networkMagic)
        #expect(mainnet.connection.networkMagic != preprod.connection.networkMagic)
        #expect(preview.connection.networkMagic != preprod.connection.networkMagic)
    }

    @Test func codableRoundTrip() throws {
        var c = CardanoNetworkConfiguration.preview
        c.logging.level = .debug
        c.metrics.enabled = false

        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(CardanoNetworkConfiguration.self, from: data)
        #expect(decoded.connection.networkMagic == c.connection.networkMagic)
        #expect(decoded.logging.level == c.logging.level)
        #expect(decoded.metrics.enabled == c.metrics.enabled)
    }

    @Test func mergedWithEnvironmentNoOverrides() {
        let base = CardanoNetworkConfiguration.preview
        let merged = base.mergedWithEnvironment()
        #expect(merged.connection.networkMagic == base.connection.networkMagic)
        #expect(merged.connection.host == base.connection.host)
        #expect(merged.connection.port == base.connection.port)
        #expect(merged.logging.level == base.logging.level)
    }

    @Test func loadFromEnvironmentReturnsDefaults() {
        // In a clean test environment, no CARDANO_* vars are set.
        let c = CardanoNetworkConfiguration.loadFromEnvironment()
        let defaults = CardanoNetworkConfiguration()
        #expect(c.connection.networkMagic == defaults.connection.networkMagic)
        #expect(c.logging.level == defaults.logging.level)
        #expect(c.metrics.enabled == defaults.metrics.enabled)
    }

    @Test func loadFromFileInvalidPathThrows() {
        #expect(throws: (any Error).self) {
            _ = try CardanoNetworkConfiguration.load(fromFile: "/nonexistent/path.json")
        }
    }

    @Test func loadFromFileValidJSON() throws {
        let json = """
        {
          "connection": { "networkMagic": 2, "host": "preview.example.com", "port": 3001,
                          "connectTimeoutSeconds": 10, "reconnectBaseDelaySeconds": 1,
                          "reconnectMaxDelaySeconds": 60 },
          "logging":    { "level": "debug", "labelPrefix": "cardano-network" },
          "metrics":    { "enabled": true, "namePrefix": "cardano_network", "globalDimensions": {} },
          "protocol":   { "ntnVersions": [14,13], "ntcVersions": [32784,32783],
                          "ntnMaxSDUSize": 12288, "ntcMaxSDUSize": 12288,
                          "keepAliveIntervalSeconds": 60, "keepAliveTimeoutSeconds": 10 }
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-config.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let c = try CardanoNetworkConfiguration.load(fromFile: url.path, mergedWithEnvironment: false)
        #expect(c.connection.networkMagic == 2)
        #expect(c.connection.host == "preview.example.com")
        #expect(c.logging.level == .debug)
    }
}
