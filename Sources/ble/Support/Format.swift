import BLESwift
import Foundation

enum Format {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    /// "+ <uuid>  -58 dBm  Name  [180D 180F]"
    static func discoveryLine(marker: String, _ discovery: Discovery) -> String {
        var parts = [
            marker,
            discovery.peripheral.uuid.uuidString,
            String(format: "%4d dBm", discovery.rssi),
            bestName(for: discovery),
        ]
        if let services = discovery.advertisement.serviceUUIDs, !services.isEmpty {
            let labels = services.map { service in
                service.name.map { "\(service.uuidString)/\($0)" } ?? service.uuidString
            }
            parts.append("[\(labels.joined(separator: " "))]")
        }
        if let manufacturerData = discovery.advertisement.manufacturerData {
            parts.append("mfr=0x\(hex(manufacturerData))")
        }
        if discovery.advertisement.isConnectable == false {
            parts.append("(not connectable)")
        }
        return parts.joined(separator: "  ")
    }

    /// Prefers the advertised local name, which is fresher than the system-cached one.
    static func bestName(for discovery: Discovery) -> String {
        discovery.advertisement.localName ?? discovery.peripheral.name
    }

    /// "180F — Battery" when the SIG assigned name is known, else just the UUID.
    static func identifier(_ uuidString: String, _ name: String?) -> String {
        name.map { "\(uuidString) — \($0)" } ?? uuidString
    }

    /// Hex plus friendly interpretations: "0x5A (1 byte, uint 90, \"Z\")".
    static func value(_ data: Data) -> String {
        var notes = ["\(data.count) byte\(data.count == 1 ? "" : "s")"]
        if !data.isEmpty, data.count <= 8 {
            let uint = data.reduce(into: (value: UInt64(0), shift: 0)) {
                $0.value |= UInt64($1) << $0.shift
                $0.shift += 8
            }.value
            notes.append("uint \(uint)")
        }
        if !data.isEmpty, let text = String(data: data, encoding: .utf8),
           text.allSatisfy({ !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " ") }) {
            notes.append("\"\(text)\"")
        }
        return "0x\(hex(data)) (\(notes.joined(separator: ", ")))"
    }

    static func properties(_ properties: CharacteristicProperties) -> String {
        let names: [(CharacteristicProperties, String)] = [
            (.read, "read"),
            (.write, "write"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"),
            (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"),
            (.broadcast, "broadcast"),
        ]
        let present = names.filter { properties.contains($0.0) }.map(\.1)
        return present.isEmpty ? "none" : present.joined(separator: ", ")
    }

    static func connectionEventLine(_ event: ConnectionEvent) -> String {
        switch event {
        case .connecting(let id):
            return "… connecting to \(id.name)"
        case .connected(let id):
            return "✓ connected to \(id.name)"
        case .reconnecting(let id, attempt: let attempt):
            return "… reconnecting to \(id.name) (attempt \(attempt))"
        case .disconnected(let id, error: let error, willReconnect: let willReconnect):
            var line = "✗ disconnected from \(id.name)"
            if let error { line += ": \(error.localizedDescription)" }
            if willReconnect { line += " — will reconnect" }
            return line
        }
    }
}
