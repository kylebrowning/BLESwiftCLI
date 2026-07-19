import ArgumentParser
import BLESwift
import Foundation

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan for nearby BLE peripherals.",
        discussion: """
        On a terminal, shows a live table sorted by signal strength (closest
        first), updating in place as advertisements arrive. When piped, with
        --stream, or with --json, prints one append-only line per sighting
        instead. Columns: name, RSSI (colored by strength), the peripheral's
        UUID (use it with `ble connect`), advertised services, manufacturer
        data. Colors turn off when piped or under NO_COLOR.
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

    @Flag(help: "Print append-only event lines instead of the live sorted table.")
    var stream = false

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

        // Live mode: an in-place table sorted by signal, for humans at a terminal.
        // Stream mode: append-only lines, for pipes, --json, and --stream.
        let live = !json && !stream && isatty(STDOUT_FILENO) == 1
        if !json && !live {
            status(Format.discoveryHeader())
        }

        let emitJSON = json
        let minRSSI = minRssi
        let rssiDelta = rssiDelta
        let allowDuplicates = allowDuplicates
        let scanTask = Task {
            var seen = Set<UUID>()
            do {
                let events = await central.scan(
                    services: serviceFilter,
                    // The live table needs repeat advertisements to keep RSSI current.
                    allowDuplicates: live || allowDuplicates,
                    rssiThreshold: rssiDelta,
                    timeout: duration
                )
                if live {
                    var table = LiveTable()
                    var rows: [UUID: (discovery: Discovery, sortRSSI: Double)] = [:]
                    table.begin()
                    defer {
                        table.render(Self.liveLines(rows), force: true)
                        table.end()
                    }
                    for try await event in events {
                        let (_, discovery) = Self.unpack(event)
                        let uuid = discovery.peripheral.uuid
                        if case .lost = event {
                            rows.removeValue(forKey: uuid)
                        } else if let minRSSI, discovery.rssi < minRSSI {
                            rows.removeValue(forKey: uuid)
                        } else {
                            rows[uuid] = (discovery, smoothedRSSI(previous: rows[uuid]?.sortRSSI, new: discovery.rssi))
                            seen.insert(uuid)
                        }
                        table.render(Self.liveLines(rows))
                    }
                } else {
                    for try await event in events {
                        let (marker, discovery) = Self.unpack(event)
                        if let minRSSI, discovery.rssi < minRSSI { continue }
                        seen.insert(discovery.peripheral.uuid)
                        if emitJSON {
                            print(try ScanRecord(marker: marker, discovery: discovery).jsonLine())
                        } else {
                            print(Format.discoveryRow(marker: marker, discovery))
                        }
                        fflush(stdout)
                    }
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

    /// Header + rows sorted strongest-signal-first (on the smoothed RSSI, so the order
    /// tracks sustained changes rather than reshuffling every advertisement) + footer.
    private static func liveLines(_ rows: [UUID: (discovery: Discovery, sortRSSI: Double)]) -> [String] {
        let sorted = rows.values.sorted {
            $0.sortRSSI != $1.sortRSSI
                ? $0.sortRSSI > $1.sortRSSI
                : Format.bestName(for: $0.discovery) < Format.bestName(for: $1.discovery)
        }
        let budget = LiveTable.visibleRowBudget()
        var lines = [Format.discoveryHeader()]
        lines += sorted.prefix(budget).map { Format.discoveryRow(marker: " ", $0.discovery) }
        var footer = "\(rows.count) in range — sorted by signal, Ctrl-C to stop"
        if sorted.count > budget {
            footer = "\(footer) (+\(sorted.count - budget) weaker not shown)"
        }
        lines.append(Style.dim(footer))
        return lines
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
