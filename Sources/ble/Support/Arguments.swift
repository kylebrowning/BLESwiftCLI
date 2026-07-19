import ArgumentParser
import BLESwift
import Foundation

/// A validated Bluetooth service UUID argument.
///
/// `ServiceIdentifier(uuid:)` traps on malformed input (mirroring `CBUUID`), so
/// validation has to happen here, before the identifier is constructed.
struct ServiceUUIDArgument: ExpressibleByArgument {
    let identifier: ServiceIdentifier

    init?(argument: String) {
        guard Self.isValidBLEUUID(argument) else { return nil }
        identifier = ServiceIdentifier(uuid: argument)
    }

    /// Accepts 4- or 8-digit hex shorthand (e.g. "180D") or a full 36-character UUID.
    static func isValidBLEUUID(_ string: String) -> Bool {
        if string.count == 4 || string.count == 8 {
            return string.allSatisfy(\.isHexDigit)
        }
        return UUID(uuidString: string) != nil
    }
}

/// Bytes supplied on the command line as hex: "deadbeef", "DE:AD:BE:EF", or "0xDEADBEEF".
struct HexBytesArgument: ExpressibleByArgument {
    let data: Data

    init?(argument: String) {
        guard let bytes = parseHexBytes(argument) else { return nil }
        data = bytes
    }
}

/// Parses "deadbeef", "DE:AD:BE:EF", or "0xDEADBEEF" into bytes.
func parseHexBytes(_ string: String) -> Data? {
    var hex = string.lowercased()
    if hex.hasPrefix("0x") { hex.removeFirst(2) }
    hex.removeAll { $0 == ":" || $0 == " " }
    guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
        return nil
    }
    var bytes = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
