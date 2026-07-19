import BLESwift
import Foundation
import Testing
@testable import ble

@Suite("Hex byte parsing")
struct HexParsingTests {

    @Test("accepted formats")
    func accepted() {
        #expect(parseHexBytes("deadbeef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(parseHexBytes("DE:AD:BE:EF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(parseHexBytes("0xDEADBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(parseHexBytes("de ad be ef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(parseHexBytes("00") == Data([0x00]))
    }

    @Test("rejected inputs")
    func rejected() {
        #expect(parseHexBytes("") == nil)
        #expect(parseHexBytes("0x") == nil)
        #expect(parseHexBytes("abc") == nil)     // odd digit count
        #expect(parseHexBytes("zz") == nil)
        #expect(parseHexBytes("👍") == nil)
    }

    @Test("HexBytesArgument wraps the parser")
    func argumentWrapper() {
        #expect(HexBytesArgument(argument: "0x01FF")?.data == Data([0x01, 0xFF]))
        #expect(HexBytesArgument(argument: "nope") == nil)
    }
}

@Suite("Bluetooth UUID validation")
struct UUIDValidationTests {

    @Test("valid shorthand and full UUIDs")
    func valid() {
        #expect(ServiceUUIDArgument.isValidBLEUUID("180D"))
        #expect(ServiceUUIDArgument.isValidBLEUUID("180d"))
        #expect(ServiceUUIDArgument.isValidBLEUUID("0000180D"))
        #expect(ServiceUUIDArgument.isValidBLEUUID("632DE001-604C-446B-A80F-7963E950F3FB"))
    }

    @Test("invalid strings never reach the trapping initializer")
    func invalid() {
        #expect(!ServiceUUIDArgument.isValidBLEUUID(""))
        #expect(!ServiceUUIDArgument.isValidBLEUUID("18"))
        #expect(!ServiceUUIDArgument.isValidBLEUUID("180"))
        #expect(!ServiceUUIDArgument.isValidBLEUUID("180DX"))
        #expect(!ServiceUUIDArgument.isValidBLEUUID("zzzz"))
        #expect(!ServiceUUIDArgument.isValidBLEUUID("632DE001-604C-446B-A80F"))
        #expect(ServiceUUIDArgument(argument: "not-a-uuid") == nil)
    }
}

@Suite("PSM argument parsing")
struct PSMTests {

    @Test("decimal and hex forms")
    func forms() {
        #expect(PSMArgument(argument: "128")?.value.rawValue == 128)
        #expect(PSMArgument(argument: "0x0080")?.value.rawValue == 0x80)
        #expect(PSMArgument(argument: "0xFFFF")?.value.rawValue == 0xFFFF)
    }

    @Test("rejected inputs")
    func rejected() {
        #expect(PSMArgument(argument: "") == nil)
        #expect(PSMArgument(argument: "0x") == nil)
        #expect(PSMArgument(argument: "65536") == nil)   // > UInt16.max
        #expect(PSMArgument(argument: "-1") == nil)
        #expect(PSMArgument(argument: "words") == nil)
    }
}

@Suite("Value formatting")
struct FormatTests {

    @Test("hex is uppercase, no separators")
    func hex() {
        #expect(Format.hex(Data([0xDE, 0xAD])) == "DEAD")
        #expect(Format.hex(Data()) == "")
    }

    @Test("value shows uint and printable text interpretations")
    func value() {
        #expect(Format.value(Data([0x5A])) == "0x5A (1 byte, uint 90, \"Z\")")
        #expect(Format.value(Data([0x88, 0x13])) == "0x8813 (2 bytes, uint 5000)")
        #expect(Format.value(Data()) == "0x (0 bytes)")
    }

    @Test("uint interpretation is little-endian and capped at 8 bytes")
    func uintInterpretation() {
        #expect(Format.value(Data([0x01, 0x00])).contains("uint 1"))
        let nineBytes = Format.value(Data(repeating: 0xFF, count: 9))
        #expect(!nineBytes.contains("uint"))
    }

    @Test("non-printable bytes get no text interpretation")
    func nonPrintable() {
        #expect(!Format.value(Data([0x00])).contains("\""))
        #expect(!Format.value(Data([0x0A])).contains("\""))
    }

    @Test("characteristic properties render by name")
    func properties() {
        #expect(Format.properties([.read, .notify]) == "read, notify")
        #expect(Format.properties([]) == "none")
        #expect(Format.properties([.write, .writeWithoutResponse]) == "write, writeWithoutResponse")
    }

    @Test("identifier labels use the assigned name when known")
    func identifierLabels() {
        #expect(Format.identifier("180F", "Battery") == "180F — Battery")
        #expect(Format.identifier("FFF0", nil) == "FFF0")
    }
}
