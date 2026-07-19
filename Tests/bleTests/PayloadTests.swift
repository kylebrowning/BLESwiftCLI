import Foundation
import Testing
@testable import ble

@Suite("Payload field encoding")
struct PayloadFieldTests {

    private func encode(_ type: String, value: PayloadScalar? = nil, length: Int? = nil) throws -> Data {
        try PayloadField(type: type, value: value, length: length).encode()
    }

    @Test("unsigned integers, little-endian by default")
    func unsignedLittleEndian() throws {
        #expect(try encode("u8", value: .unsigned(1)) == Data([0x01]))
        #expect(try encode("u16", value: .unsigned(5000)) == Data([0x88, 0x13]))
        #expect(try encode("u16le", value: .unsigned(5000)) == Data([0x88, 0x13]))
        #expect(try encode("u32", value: .unsigned(0x01020304)) == Data([0x04, 0x03, 0x02, 0x01]))
        #expect(try encode("u64", value: .unsigned(.max)) == Data(repeating: 0xFF, count: 8))
    }

    @Test("big-endian suffix")
    func bigEndian() throws {
        #expect(try encode("u16be", value: .unsigned(5000)) == Data([0x13, 0x88]))
        #expect(try encode("u32be", value: .unsigned(0x01020304)) == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(try encode("i16be", value: .signed(-2)) == Data([0xFF, 0xFE]))
    }

    @Test("signed integers use two's complement")
    func signedTwosComplement() throws {
        #expect(try encode("i8", value: .signed(-1)) == Data([0xFF]))
        #expect(try encode("i16", value: .signed(-2)) == Data([0xFE, 0xFF]))
        #expect(try encode("i32le", value: .signed(-70)) == Data([0xBA, 0xFF, 0xFF, 0xFF]))
        #expect(try encode("i64", value: .signed(Int64.min)) == Data([0, 0, 0, 0, 0, 0, 0, 0x80]))
    }

    @Test("boundary values fit exactly")
    func boundaries() throws {
        #expect(try encode("u8", value: .unsigned(255)) == Data([0xFF]))
        #expect(try encode("i8", value: .signed(-128)) == Data([0x80]))
        #expect(try encode("i8", value: .unsigned(127)) == Data([0x7F]))
        #expect(try encode("u16", value: .unsigned(65535)) == Data([0xFF, 0xFF]))
    }

    @Test("out-of-range values are rejected")
    func outOfRange() {
        #expect(throws: CLIError.self) { try encode("u8", value: .unsigned(256)) }
        #expect(throws: CLIError.self) { try encode("i8", value: .unsigned(128)) }
        #expect(throws: CLIError.self) { try encode("i8", value: .signed(-129)) }
        #expect(throws: CLIError.self) { try encode("u16", value: .unsigned(65536)) }
        #expect(throws: CLIError.self) { try encode("i64", value: .unsigned(UInt64(Int64.max) + 1)) }
    }

    @Test("negative values are rejected for unsigned types")
    func negativeUnsigned() {
        #expect(throws: CLIError.self) { try encode("u8", value: .signed(-1)) }
    }

    @Test("string and hex fields")
    func stringAndHex() throws {
        #expect(try encode("string", value: .text("hi")) == Data([0x68, 0x69]))
        #expect(try encode("hex", value: .text("DEADBEEF")) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try encode("hex", value: .text("0xde:ad")) == Data([0xDE, 0xAD]))
        #expect(throws: CLIError.self) { try encode("hex", value: .text("XYZ")) }
        #expect(throws: CLIError.self) { try encode("string", value: .unsigned(5)) }
    }

    @Test("pad emits zeroes and requires a positive length")
    func pad() throws {
        #expect(try encode("pad", length: 3) == Data([0, 0, 0]))
        #expect(throws: CLIError.self) { try encode("pad") }
        #expect(throws: CLIError.self) { try encode("pad", length: 0) }
    }

    @Test("varint uses LEB128 encoding")
    func varint() throws {
        #expect(try encode("varint", value: .unsigned(0)) == Data([0x00]))
        #expect(try encode("varint", value: .unsigned(1)) == Data([0x01]))
        #expect(try encode("varint", value: .unsigned(127)) == Data([0x7F]))
        #expect(try encode("varint", value: .unsigned(128)) == Data([0x80, 0x01]))
        #expect(try encode("varint", value: .unsigned(300)) == Data([0xAC, 0x02]))
        #expect(try encode("varint", value: .unsigned(1_411_519)) == Data([0xBF, 0x93, 0x56]))
        #expect(try encode("varint", value: .unsigned(.max)) == Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
        #expect(throws: CLIError.self) { try encode("varint", value: .signed(-1)) }
        #expect(throws: CLIError.self) { try encode("varint") }
    }

    @Test("unknown types and missing values are rejected")
    func unknownAndMissing() {
        #expect(throws: CLIError.self) { try encode("float32", value: .unsigned(1)) }
        #expect(throws: CLIError.self) { try encode("u16") }
    }
}

@Suite("Payload file parsing")
struct PayloadFileTests {

    private func write(_ contents: String, ext: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ble-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("YAML file with target and fields encodes in order")
    func yamlRoundTrip() throws {
        let path = try write("""
        service: 180F
        characteristic: 2A19
        writeType: withoutResponse
        fields:
          - { type: u8,    value: 1 }
          - { type: u16le, value: 5000 }
          - { type: hex,   value: "BEEF" }
          - { type: pad,   length: 2 }
        """, ext: "yaml")
        let file = try PayloadFile.load(atPath: path)
        #expect(file.service == "180F")
        #expect(file.characteristic == "2A19")
        #expect(file.writeType == "withoutResponse")
        #expect(try file.encodedData() == Data([0x01, 0x88, 0x13, 0xBE, 0xEF, 0x00, 0x00]))
    }

    @Test("JSON parses through the same decoder")
    func jsonRoundTrip() throws {
        let path = try write("""
        {"fields":[{"type":"u16be","value":65535},{"type":"i8","value":-1}]}
        """, ext: "json")
        let file = try PayloadFile.load(atPath: path)
        #expect(file.service == nil)
        #expect(try file.encodedData() == Data([0xFF, 0xFF, 0xFF]))
    }

    @Test("field errors carry the 1-based field index")
    func fieldErrorIndex() throws {
        let path = try write("""
        fields:
          - { type: u8, value: 1 }
          - { type: u8, value: 300 }
        """, ext: "yaml")
        let file = try PayloadFile.load(atPath: path)
        do {
            _ = try file.encodedData()
            Issue.record("expected an encoding error")
        } catch let error as CLIError {
            #expect(error.description.hasPrefix("Field 2"))
        }
    }

    @Test("invalid writeType is rejected at load")
    func invalidWriteType() throws {
        let path = try write("""
        writeType: nonsense
        fields: []
        """, ext: "yaml")
        #expect(throws: CLIError.self) { try PayloadFile.load(atPath: path) }
    }

    @Test("missing file and malformed file produce CLIError")
    func loadFailures() throws {
        #expect(throws: CLIError.self) { try PayloadFile.load(atPath: "/nonexistent/path.yaml") }
        let path = try write("fields: {not: a list}", ext: "yaml")
        #expect(throws: CLIError.self) { try PayloadFile.load(atPath: path) }
    }
}
