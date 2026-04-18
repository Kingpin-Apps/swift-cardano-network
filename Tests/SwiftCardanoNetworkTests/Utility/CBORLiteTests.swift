import Testing
import NIOCore
@testable import SwiftCardanoNetwork

// MARK: - Helpers

private let alloc = ByteBufferAllocator()

/// Write then read back, assert equality.
private func roundTripUInt(_ v: UInt64) throws -> UInt64 {
    var buf = alloc.buffer(capacity: 16)
    CBORLite.writeUInt(v, into: &buf)
    return try CBORLite.readUInt(from: &buf)
}

// MARK: - UInt

@Suite("CBORLite UInt") struct CBORLiteUIntTests {
    @Test func zeroRoundTrip()   throws { #expect(try roundTripUInt(0)   == 0) }
    @Test func tinyRoundTrip()   throws { #expect(try roundTripUInt(23)  == 23) }
    @Test func oneByte()         throws { #expect(try roundTripUInt(24)  == 24) }
    @Test func maxOneByte()      throws { #expect(try roundTripUInt(255) == 255) }
    @Test func twoByte()         throws { #expect(try roundTripUInt(256) == 256) }
    @Test func maxTwoByte()      throws { #expect(try roundTripUInt(65535) == 65535) }
    @Test func fourByte()        throws { #expect(try roundTripUInt(65536) == 65536) }
    @Test func maxFourByte()     throws { #expect(try roundTripUInt(0xFFFF_FFFF) == 0xFFFF_FFFF) }
    @Test func eightByte()       throws { #expect(try roundTripUInt(0x1_0000_0000) == 0x1_0000_0000) }
    @Test func largeValue()      throws { #expect(try roundTripUInt(UInt64.max / 2) == UInt64.max / 2) }

    @Test func firstByteForTiny() {
        var buf = alloc.buffer(capacity: 1)
        CBORLite.writeUInt(17, into: &buf)
        // Major type 0 (uint) | 17 = 0x11
        #expect(buf.getInteger(at: 0, as: UInt8.self) == 0x11)
    }

    @Test func typeMismatchThrows() {
        // Write a byte string, try to read as uint.
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeByteString([], into: &buf)
        #expect(throws: (any Error).self) { try CBORLite.readUInt(from: &buf) }
    }

    @Test func truncatedThrows() {
        var buf = alloc.buffer(capacity: 0)
        #expect(throws: (any Error).self) { try CBORLite.readUInt(from: &buf) }
    }
}

// MARK: - Byte string

@Suite("CBORLite ByteString") struct CBORLiteByteStringTests {
    @Test func emptyRoundTrip() throws {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeByteString([], into: &buf)
        let decoded = try CBORLite.readByteString(from: &buf)
        #expect(decoded.isEmpty)
    }

    @Test func shortRoundTrip() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0xAB, 0xCD, 0xFF]
        var buf = alloc.buffer(capacity: 32)
        CBORLite.writeByteString(bytes, into: &buf)
        let decoded = try CBORLite.readByteString(from: &buf)
        #expect(decoded == bytes)
    }

    @Test func longRoundTrip() throws {
        let bytes = Array(0..<256).map { UInt8($0 & 0xFF) }
        var buf = alloc.buffer(capacity: 512)
        CBORLite.writeByteString(bytes, into: &buf)
        let decoded = try CBORLite.readByteString(from: &buf)
        #expect(decoded == bytes)
    }

    @Test func byteBufferRoundTrip() throws {
        var src = alloc.buffer(capacity: 4)
        src.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        var buf = alloc.buffer(capacity: 8)
        CBORLite.writeByteBuffer(src, into: &buf)
        let decoded = try CBORLite.readByteStringBuffer(from: &buf)
        #expect(decoded.readableBytes == 4)
    }

    @Test func typeMismatchThrows() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeUInt(42, into: &buf)
        #expect(throws: (any Error).self) { try CBORLite.readByteString(from: &buf) }
    }
}

// MARK: - Text string

@Suite("CBORLite Text") struct CBORLiteTextTests {
    @Test func emptyRoundTrip() throws {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeText("", into: &buf)
        let decoded = try CBORLite.readText(from: &buf)
        #expect(decoded == "")
    }

    @Test func asciiRoundTrip() throws {
        let s = "hello, cardano!"
        var buf = alloc.buffer(capacity: 32)
        CBORLite.writeText(s, into: &buf)
        let decoded = try CBORLite.readText(from: &buf)
        #expect(decoded == s)
    }

    @Test func longStringRoundTrip() throws {
        let s = String(repeating: "x", count: 300)
        var buf = alloc.buffer(capacity: 350)
        CBORLite.writeText(s, into: &buf)
        let decoded = try CBORLite.readText(from: &buf)
        #expect(decoded == s)
    }

    @Test func typeMismatchThrows() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeUInt(1, into: &buf)
        #expect(throws: (any Error).self) { try CBORLite.readText(from: &buf) }
    }
}

// MARK: - Array header

@Suite("CBORLite ArrayHeader") struct CBORLiteArrayHeaderTests {
    @Test func zeroElements() throws {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 0, into: &buf)
        let count = try CBORLite.readArrayHeader(from: &buf)
        #expect(count == 0)
    }

    @Test func tinyCount() throws {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 23, into: &buf)
        #expect(try CBORLite.readArrayHeader(from: &buf) == 23)
    }

    @Test func oneByteLengthCount() throws {
        var buf = alloc.buffer(capacity: 4)
        CBORLite.writeArrayHeader(count: 255, into: &buf)
        #expect(try CBORLite.readArrayHeader(from: &buf) == 255)
    }

    @Test func twoByteLengthCount() throws {
        var buf = alloc.buffer(capacity: 8)
        CBORLite.writeArrayHeader(count: 1000, into: &buf)
        #expect(try CBORLite.readArrayHeader(from: &buf) == 1000)
    }

    @Test func typeMismatchThrows() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeMapHeader(count: 1, into: &buf)
        #expect(throws: (any Error).self) { try CBORLite.readArrayHeader(from: &buf) }
    }
}

// MARK: - Map header

@Suite("CBORLite MapHeader") struct CBORLiteMapHeaderTests {
    @Test func roundTrip() throws {
        for count in [0, 1, 23, 24, 100] {
            var buf = alloc.buffer(capacity: 8)
            CBORLite.writeMapHeader(count: count, into: &buf)
            #expect(try CBORLite.readMapHeader(from: &buf) == count)
        }
    }

    @Test func typeMismatchThrows() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 1, into: &buf)
        #expect(throws: (any Error).self) { try CBORLite.readMapHeader(from: &buf) }
    }
}

// MARK: - Tag

@Suite("CBORLite Tag") struct CBORLiteTagTests {
    @Test func tag24RoundTrip() throws {
        var buf = alloc.buffer(capacity: 4)
        CBORLite.writeTag(24, into: &buf)
        let tag = try CBORLite.readTag(from: &buf)
        #expect(tag == 24)
    }

    @Test func largTagRoundTrip() throws {
        var buf = alloc.buffer(capacity: 8)
        CBORLite.writeTag(1000, into: &buf)
        let tag = try CBORLite.readTag(from: &buf)
        #expect(tag == 1000)
    }

    @Test func typeMismatchThrows() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeUInt(24, into: &buf)  // uint 24, not a tag
        #expect(throws: (any Error).self) { try CBORLite.readTag(from: &buf) }
    }
}

// MARK: - Bool

@Suite("CBORLite Bool") struct CBORLiteBoolTests {
    @Test func trueRoundTrip() throws {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeBool(true, into: &buf)
        #expect(try CBORLite.readBool(from: &buf) == true)
    }

    @Test func falseRoundTrip() throws {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeBool(false, into: &buf)
        #expect(try CBORLite.readBool(from: &buf) == false)
    }

    @Test func typeMismatchThrows() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeUInt(1, into: &buf)
        #expect(throws: (any Error).self) { try CBORLite.readBool(from: &buf) }
    }
}

// MARK: - peekMajorType

@Suite("CBORLite peekMajorType") struct CBORLitePeekMajorTypeTests {
    @Test func peeksUInt() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeUInt(5, into: &buf)
        #expect(CBORLite.peekMajorType(from: buf) == CBORLite.majorUInt)
    }

    @Test func peeksByteString() {
        var buf = alloc.buffer(capacity: 4)
        CBORLite.writeByteString([0x01], into: &buf)
        #expect(CBORLite.peekMajorType(from: buf) == CBORLite.majorByteString)
    }

    @Test func peeksArrayMajorType() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 3, into: &buf)
        #expect(CBORLite.peekMajorType(from: buf) == CBORLite.majorArray)
    }

    @Test func peeksTagMajorType() {
        var buf = alloc.buffer(capacity: 4)
        CBORLite.writeTag(24, into: &buf)
        #expect(CBORLite.peekMajorType(from: buf) == CBORLite.majorTag)
    }

    @Test func returnsNilForEmptyBuffer() {
        let buf = alloc.buffer(capacity: 0)
        #expect(CBORLite.peekMajorType(from: buf) == nil)
    }
}

// MARK: - skipValue

@Suite("CBORLite skipValue") struct CBORLiteSkipValueTests {
    @Test func skipUInt() throws {
        var buf = alloc.buffer(capacity: 4)
        CBORLite.writeUInt(42, into: &buf)
        CBORLite.writeUInt(99, into: &buf)
        try CBORLite.skipValue(in: &buf)
        // Only the second value should remain.
        let remaining = try CBORLite.readUInt(from: &buf)
        #expect(remaining == 99)
    }

    @Test func skipByteString() throws {
        var buf = alloc.buffer(capacity: 16)
        CBORLite.writeByteString([0x01, 0x02, 0x03], into: &buf)
        CBORLite.writeUInt(7, into: &buf)
        try CBORLite.skipValue(in: &buf)
        #expect(try CBORLite.readUInt(from: &buf) == 7)
    }

    @Test func skipText() throws {
        var buf = alloc.buffer(capacity: 16)
        CBORLite.writeText("skip me", into: &buf)
        CBORLite.writeUInt(3, into: &buf)
        try CBORLite.skipValue(in: &buf)
        #expect(try CBORLite.readUInt(from: &buf) == 3)
    }

    @Test func skipNestedArray() throws {
        var buf = alloc.buffer(capacity: 32)
        // Write [[1, 2], 3]
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeArrayHeader(count: 2, into: &buf)
        CBORLite.writeUInt(1, into: &buf)
        CBORLite.writeUInt(2, into: &buf)
        CBORLite.writeUInt(3, into: &buf)
        // Sentinel
        CBORLite.writeUInt(99, into: &buf)

        try CBORLite.skipValue(in: &buf)  // skips the whole outer array
        #expect(try CBORLite.readUInt(from: &buf) == 99)
    }

    @Test func skipMap() throws {
        var buf = alloc.buffer(capacity: 32)
        CBORLite.writeMapHeader(count: 2, into: &buf)
        CBORLite.writeText("a", into: &buf); CBORLite.writeUInt(1, into: &buf)
        CBORLite.writeText("b", into: &buf); CBORLite.writeUInt(2, into: &buf)
        CBORLite.writeUInt(55, into: &buf)

        try CBORLite.skipValue(in: &buf)
        #expect(try CBORLite.readUInt(from: &buf) == 55)
    }

    @Test func skipTaggedValue() throws {
        var buf = alloc.buffer(capacity: 16)
        CBORLite.writeTag(24, into: &buf)
        CBORLite.writeByteString([0xAB, 0xCD], into: &buf)
        CBORLite.writeUInt(77, into: &buf)

        try CBORLite.skipValue(in: &buf)
        #expect(try CBORLite.readUInt(from: &buf) == 77)
    }
}

// MARK: - CBORError

@Suite("CBORError") struct CBORErrorTests {
    @Test func truncatedError() {
        var buf = alloc.buffer(capacity: 0)
        let result = Result { try CBORLite.readUInt(from: &buf) }
        switch result {
        case .failure(let err as CBORError):
            if case .truncated = err { /* pass */ }
            else { Issue.record("Expected .truncated, got \(err)") }
        default:
            Issue.record("Expected failure")
        }
    }

    @Test func typeMismatchError() {
        var buf = alloc.buffer(capacity: 2)
        CBORLite.writeArrayHeader(count: 1, into: &buf)
        let result = Result { try CBORLite.readUInt(from: &buf) }
        switch result {
        case .failure(let err as CBORError):
            if case .typeMismatch = err { /* pass */ }
            else { Issue.record("Expected .typeMismatch, got \(err)") }
        default:
            Issue.record("Expected failure")
        }
    }
}
