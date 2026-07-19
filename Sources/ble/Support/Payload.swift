import Foundation
import Yams

/// A structured write payload loaded from a YAML or JSON file.
///
/// The file describes an ordered list of typed fields that are encoded and
/// concatenated into the bytes written to the characteristic. It may also name
/// the target, making the file a self-contained device command:
///
/// ```yaml
/// service: 180F
/// characteristic: 2A19
/// writeType: withResponse   # optional; withResponse | withoutResponse
/// fields:
///   - { type: u8,     value: 1 }
///   - { type: u16le,  value: 5000 }
///   - { type: i32be,  value: -70 }
///   - { type: string, value: "hello" }
///   - { type: hex,    value: "DEADBEEF" }
///   - { type: pad,    length: 2 }
/// ```
///
/// Integer types are u8/u16/u32/u64 and i8/i16/i32/i64 with an optional `le`
/// (default) or `be` endianness suffix. JSON files parse through the same
/// decoder — JSON is valid YAML.
struct PayloadFile: Decodable {
    var service: String?
    var characteristic: String?
    var writeType: String?
    var fields: [PayloadField]

    static func load(atPath path: String) throws -> PayloadFile {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CLIError("Could not read payload file '\(path)': \(error.localizedDescription)")
        }
        do {
            let file = try YAMLDecoder().decode(PayloadFile.self, from: text)
            if let writeType = file.writeType,
               !["withResponse", "withoutResponse"].contains(writeType) {
                throw CLIError("Invalid writeType '\(writeType)' — use withResponse or withoutResponse.")
            }
            return file
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("Could not parse payload file '\(path)': \(error.localizedDescription)")
        }
    }

    func encodedData() throws -> Data {
        var data = Data()
        for (index, field) in fields.enumerated() {
            do {
                data.append(try field.encode())
            } catch let error as CLIError {
                throw CLIError("Field \(index + 1) (\(field.type)): \(error.description)")
            }
        }
        return data
    }
}

struct PayloadField: Decodable {
    let type: String
    let value: PayloadScalar?
    let length: Int?

    func encode() throws -> Data {
        switch type {
        case "string":
            guard case .text(let text) = try requiredValue() else {
                throw CLIError("expected a string value")
            }
            return Data(text.utf8)
        case "hex":
            guard case .text(let text) = try requiredValue(), let bytes = parseHexBytes(text) else {
                throw CLIError("expected a hex string value like \"DEADBEEF\"")
            }
            return bytes
        case "pad":
            guard let length, length > 0 else {
                throw CLIError("pad requires a positive 'length'")
            }
            return Data(count: length)
        case "varint":
            guard case .unsigned(let magnitude) = try requiredValue() else {
                throw CLIError("varint requires a non-negative integer value")
            }
            var remaining = magnitude
            var bytes = Data()
            repeat {
                var byte = UInt8(remaining & 0x7F)
                remaining >>= 7
                if remaining > 0 { byte |= 0x80 }
                bytes.append(byte)
            } while remaining > 0
            return bytes
        default:
            return try encodeInteger()
        }
    }

    private func requiredValue() throws -> PayloadScalar {
        guard let value else { throw CLIError("missing 'value'") }
        return value
    }

    private func encodeInteger() throws -> Data {
        var name = type
        var littleEndian = true
        if name.hasSuffix("le") {
            name.removeLast(2)
        } else if name.hasSuffix("be") {
            name.removeLast(2)
            littleEndian = false
        }

        let widths: [String: Int] = [
            "u8": 1, "u16": 2, "u32": 4, "u64": 8,
            "i8": 1, "i16": 2, "i32": 4, "i64": 8,
        ]
        guard let byteCount = widths[name] else {
            throw CLIError("""
            unknown field type '\(type)' — use u8/u16/u32/u64, i8/i16/i32/i64 \
            (optional le/be suffix), varint, string, hex, or pad
            """)
        }

        let bits = byteCount * 8
        var raw: UInt64
        if name.hasPrefix("u") {
            guard case .unsigned(let magnitude) = try requiredValue() else {
                throw CLIError("expected a non-negative integer value")
            }
            guard byteCount == 8 || magnitude < (1 << bits) else {
                throw CLIError("value \(magnitude) does not fit in \(name)")
            }
            raw = magnitude
        } else {
            let signed: Int64 = switch try requiredValue() {
            case .signed(let v): v
            case .unsigned(let v) where v <= UInt64(Int64.max): Int64(v)
            default: throw CLIError("expected an integer value that fits in \(name)")
            }
            if byteCount < 8 {
                let bound: Int64 = 1 << (bits - 1)
                guard signed >= -bound, signed < bound else {
                    throw CLIError("value \(signed) does not fit in \(name)")
                }
            }
            raw = UInt64(bitPattern: signed)
        }

        var bytes = [UInt8]()
        for shift in 0..<byteCount {
            bytes.append(UInt8(truncatingIfNeeded: raw >> (shift * 8)))
        }
        return Data(littleEndian ? bytes : bytes.reversed())
    }
}

/// A field value that may arrive from YAML/JSON as an integer or a string.
enum PayloadScalar: Decodable {
    case signed(Int64)
    case unsigned(UInt64)
    case text(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let signed = try? container.decode(Int64.self) {
            self = signed >= 0 ? .unsigned(UInt64(signed)) : .signed(signed)
        } else if let unsigned = try? container.decode(UInt64.self) {
            self = .unsigned(unsigned)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "field 'value' must be an integer or a string"
            )
        }
    }
}
