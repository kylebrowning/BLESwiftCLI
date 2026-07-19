import BLESwift
import Foundation

/// Minimal ANSI styling for stdout, on only when stdout is an interactive terminal
/// (so piped output stays plain), and honoring the NO_COLOR convention.
enum Style {
    static let enabled: Bool =
        isatty(STDOUT_FILENO) == 1
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"

    private static func apply(_ code: Int, to text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { apply(1, to: text) }
    static func dim(_ text: String) -> String { apply(2, to: text) }
    static func red(_ text: String) -> String { apply(31, to: text) }
    static func green(_ text: String) -> String { apply(32, to: text) }
    static func yellow(_ text: String) -> String { apply(33, to: text) }
    static func cyan(_ text: String) -> String { apply(36, to: text) }
}

enum Format {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    /// Fixed column widths for the scan table. UUID strings are always 36 characters.
    static let nameColumnWidth = 26
    private static let uuidColumnWidth = 36

    /// Left-aligns `text` in a `width`-character cell, truncating with an ellipsis.
    /// Pad *before* styling — ANSI escapes would otherwise count toward the width.
    static func pad(_ text: String, to width: Int) -> String {
        guard text.count <= width else { return text.prefix(width - 1) + "…" }
        return text + String(repeating: " ", count: width - text.count)
    }

    /// Column header matching ``discoveryRow(marker:_:)`` — print it to stderr so
    /// stdout stays pure data.
    static func discoveryHeader() -> String {
        Style.dim("   " + pad("NAME", to: nameColumnWidth) + "  RSSI  " + pad("UUID", to: uuidColumnWidth) + "  DETAILS")
    }

    /// "+  Name         -58  <uuid>  [180D 180F]" — name first, RSSI colored by
    /// strength, UUID dimmed, services/manufacturer data as a free-form tail.
    static func discoveryRow(marker: String, _ discovery: Discovery) -> String {
        let markerStyled = switch marker {
        case "+": Style.green(marker)
        case "~": Style.yellow(marker)
        default: Style.red(marker)
        }

        let name = pad(bestName(for: discovery), to: nameColumnWidth)
        let nameStyled = marker == "-" ? Style.dim(name) : Style.bold(name)

        let rssiText = String(format: "%4d", discovery.rssi)
        let rssiStyled = discovery.rssi >= -60 ? Style.green(rssiText)
            : discovery.rssi >= -75 ? Style.yellow(rssiText)
            : Style.red(rssiText)

        var parts = [
            markerStyled,
            nameStyled,
            rssiStyled,
            Style.dim(discovery.peripheral.uuid.uuidString),
        ]
        if let services = discovery.advertisement.serviceUUIDs, !services.isEmpty {
            let labels = services.map { service in
                service.name.map { "\(service.uuidString)/\($0)" } ?? service.uuidString
            }
            parts.append(Style.cyan("[\(labels.joined(separator: " "))]"))
        }
        if let manufacturerData = discovery.advertisement.manufacturerData {
            parts.append(Style.dim("mfr=0x\(hex(manufacturerData))"))
        }
        if discovery.advertisement.isConnectable == false {
            parts.append(Style.dim("(not connectable)"))
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
