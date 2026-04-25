/// Errors thrown when decoding ledger state query responses from CBOR.
public enum LedgerStateDecodingError: Error, Sendable {
    case unexpectedFormat(String)
}
