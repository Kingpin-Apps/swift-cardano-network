/// Errors that can occur in the multiplexer layer.
public enum MuxError: Error, Sendable {
    case payloadTooLarge(protocolID: UInt16, length: Int, max: Int)
    case incompleteFrame
    case unknownProtocol(UInt16)
}
