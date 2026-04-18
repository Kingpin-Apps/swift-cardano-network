import NIOCore

// MARK: - Version tables

/// NtN protocol version constants (Conway era = 14).
public enum NodeToNodeVersion {
    public static let v7:  UInt16 = 7
    public static let v8:  UInt16 = 8
    public static let v9:  UInt16 = 9
    public static let v10: UInt16 = 10
    public static let v11: UInt16 = 11
    public static let v12: UInt16 = 12
    public static let v13: UInt16 = 13
    public static let v14: UInt16 = 14  // Conway
}

/// NtN protocol version v15 (post-Conway).
extension NodeToNodeVersion {
    public static let v15: UInt16 = 15
}

/// NtC protocol version constants.
///
/// Wire values include bit 15 (0x8000 = 32768) per spec §3.1.
public enum NodeToClientVersion {
    public static let v9:  UInt16 = 32777   // 32768 + 9
    public static let v14: UInt16 = 32782   // 32768 + 14
    public static let v15: UInt16 = 32783   // 32768 + 15
    public static let v16: UInt16 = 32784   // 32768 + 16  (Conway)
    public static let v17: UInt16 = 32785
    public static let v18: UInt16 = 32786
    public static let v19: UInt16 = 32787
    public static let v20: UInt16 = 32788
    public static let v21: UInt16 = 32789
}

// MARK: - Version data

/// The version-specific data payload exchanged during Handshake.
public enum HandshakeVersionData: Sendable {
    /// NtN: `[networkMagic, diffusionMode]`
    case nodeToNode(networkMagic: UInt32, initiatorOnly: Bool, peerSharing: UInt8?, query: Bool?)
    /// NtC: `[networkMagic, query]` (v15+) or bare `networkMagic` (v9/v14)
    case nodeToClient(networkMagic: UInt32, query: Bool = false)
}

// MARK: - Messages

/// The Handshake mini-protocol message set.
public enum HandshakeMessage: Sendable {
    // Client → Server
    /// Propose a set of supported versions. The server picks the highest it accepts.
    case proposeVersions([UInt16: HandshakeVersionData])

    // Server → Client
    /// The server accepted `version` with the given version data.
    case acceptVersion(UInt16, HandshakeVersionData)
    /// The server refused the handshake.
    case refuse(RefuseReason)
}

/// The reasons a remote node may refuse a Handshake.
public enum RefuseReason: Sendable {
    /// None of the proposed versions are supported. Carries the server's version list.
    case versionMismatch([UInt16])
    /// The server could not decode the version data for `version`.
    case handshakeDecodeError(UInt16, String)
    /// The server explicitly refused `version` with a reason string.
    case refused(UInt16, String)
}

// MARK: - Negotiated result

public struct NegotiatedVersion: Sendable {
    public let version: UInt16
    public let versionData: HandshakeVersionData
}
