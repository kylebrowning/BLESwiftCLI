import ArgumentParser
import BLESwift
import Foundation

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan for nearby BLE peripherals.",
        discussion: """
        Prints one line per sighting: the peripheral's UUID (use it with
        `ble connect`), RSSI, name, advertised services, and manufacturer data.
        """
    )

    @Option(
        name: [.customShort("s"), .customLong("service")],
        help: "Only report peripherals advertising this service UUID. Repeatable."
    )
    var services: [ServiceUUIDArgument] = []

    @Option(name: .shortAndLong, help: "Stop after this many seconds. 0 scans until Ctrl-C.")
    var timeout: Double = 10

    @Flag(help: "Track advertisement updates and losses, not just first sightings.")
    var allowDuplicates = false

    @Option(
        parsing: .unconditional,
        help: "Hide peripherals with a signal weaker than this RSSI (e.g. -70)."
    )
    var minRssi: Int?

    @Option(
        parsing: .unconditional,
        help: "With --allow-duplicates, only report an update when RSSI changed by at least this many dBm."
    )
    var rssiDelta: Int?

    @Flag(help: "Emit one JSON object per line instead of formatted text.")
    var json = false

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    func run() async throws {
        let central = Radio.makeCentral(verbose: verbose)
        try await Radio.waitUntilReady(central)

        let serviceFilter = services.isEmpty ? nil : services.map(\.identifier)
        let duration: Duration? = timeout > 0 ? .seconds(timeout) : nil
        var scope = serviceFilter.map { "for services \($0.map(\.uuidString).joined(separator: ", "))" }
            ?? "for all peripherals"
        scope += duration.map { _ in " (\(Int(timeout))s)" } ?? " (Ctrl-C to stop)"
        status("Scanning \(scope)…")

        let emitJSON = json
        let minRSSI = minRssi
        let rssiDelta = rssiDelta
        let scanTask = Task {
            var seen = Set<UUID>()
            do {
                let events = await central.scan(
                    services: serviceFilter,
                    allowDuplicates: allowDuplicates,
                    rssiThreshold: rssiDelta,
                    timeout: duration
                )
                for try await event in events {
                    let (marker, discovery) = Self.unpack(event)
                    if let minRSSI, discovery.rssi < minRSSI { continue }
                    seen.insert(discovery.peripheral.uuid)
                    if emitJSON {
                        print(try ScanRecord(marker: marker, discovery: discovery).jsonLine())
                    } else {
                        print(Format.discoveryLine(marker: marker, discovery))
                    }
                    fflush(stdout)
                }
            } catch is CancellationError {
            } catch let error as BLESwiftError where error == .cancelled || error == .operationCancelled {
            }
            return seen.count
        }
        let interruptTask = Task {
            await Interrupt.wait()
            scanTask.cancel()
        }
        let count = try await scanTask.value
        interruptTask.cancel()

        status("Done — \(count) peripheral\(count == 1 ? "" : "s") seen.")
    }

    private static func unpack(_ event: ScanEvent) -> (marker: String, discovery: Discovery) {
        switch event {
        case .discovered(let discovery): ("+", discovery)
        case .updated(let discovery): ("~", discovery)
        case .lost(let discovery): ("-", discovery)
        }
    }
}

private struct ScanRecord: Encodable {
    let event: String
    let uuid: String
    let name: String
    let rssi: Int
    let services: [String]?
    let manufacturerData: String?
    let txPowerLevel: Int?
    let connectable: Bool?

    init(marker: String, discovery: Discovery) {
        event = switch marker {
        case "+": "discovered"
        case "~": "updated"
        default: "lost"
        }
        uuid = discovery.peripheral.uuid.uuidString
        name = Format.bestName(for: discovery)
        rssi = discovery.rssi
        services = discovery.advertisement.serviceUUIDs?.map(\.uuidString)
        manufacturerData = discovery.advertisement.manufacturerData.map(Format.hex)
        txPowerLevel = discovery.advertisement.txPowerLevel
        connectable = discovery.advertisement.isConnectable
    }

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
