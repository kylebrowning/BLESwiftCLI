import ArgumentParser
import BLESwift
import Foundation

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Browse a peripheral's full GATT tree.",
        discussion: """
        Connects and enumerates every service, characteristic (with its
        property flags), and descriptor — no UUIDs needed up front. Standard
        Bluetooth SIG attributes are labeled with their assigned names.

        With --read, readable characteristic values are read and shown inline.
        Note that reading a protected characteristic can trigger the macOS
        pairing dialog, just like `ble pair`.
        """
    )

    @Argument(help: "Peripheral UUID from `ble scan`, or a name substring.")
    var peripheral: String

    @Option(
        name: [.customShort("s"), .customLong("service")],
        help: "Narrow the resolution scan to this service UUID. Repeatable."
    )
    var services: [ServiceUUIDArgument] = []

    @Flag(help: "Also read and show the value of each readable characteristic.")
    var read = false

    @Flag(help: "Emit the GATT tree as JSON instead of formatted text.")
    var json = false

    @Option(help: "Seconds to scan while resolving the peripheral.")
    var scanTimeout: Double = 15

    @Option(name: .shortAndLong, help: "Seconds to wait for the connection to establish.")
    var timeout: Double = 15

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    func run() async throws {
        let serviceFilter = services.isEmpty ? nil : services.map(\.identifier)
        let dump = try await Session.withPeripheral(
            peripheral,
            services: serviceFilter,
            scanTimeout: scanTimeout,
            connectTimeout: timeout,
            verbose: verbose
        ) { _, connected in
            try await gather(from: connected)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(dump), as: UTF8.self))
        } else {
            render(dump)
        }
    }

    private func gather(from connected: Peripheral) async throws -> GATTDump {
        var services: [GATTDump.Service] = []
        for service in try await connected.discoverServices() {
            var characteristics: [GATTDump.Characteristic] = []
            let discovered: [CharacteristicIdentifier]
            do {
                discovered = try await connected.discoverCharacteristics(for: service)
            } catch {
                status("Warning: characteristic discovery failed for \(service.uuidString): \(error.localizedDescription)")
                services.append(.init(uuid: service.uuidString, name: service.name, characteristics: []))
                continue
            }
            for characteristic in discovered {
                let properties = try? await connected.properties(of: characteristic)
                var value: Data?
                var readFailure: String?
                if read, let properties, properties.contains(.read) {
                    do {
                        value = try await connected.read(from: characteristic, timeout: .seconds(5))
                    } catch {
                        readFailure = error.localizedDescription
                    }
                }
                let descriptors = (try? await connected.discoverDescriptors(for: characteristic)) ?? []
                characteristics.append(.init(
                    uuid: characteristic.uuidString,
                    name: characteristic.name,
                    properties: properties.map(propertyNames) ?? [],
                    value: value.map(Format.hex),
                    readFailure: readFailure,
                    descriptors: descriptors.map { .init(uuid: $0.uuidString, name: $0.name) }
                ))
            }
            services.append(.init(uuid: service.uuidString, name: service.name, characteristics: characteristics))
        }
        let id = connected.id
        return GATTDump(peripheral: .init(uuid: id.uuid.uuidString, name: id.name), services: services)
    }

    private func propertyNames(_ properties: CharacteristicProperties) -> [String] {
        Format.properties(properties).components(separatedBy: ", ").filter { $0 != "none" }
    }

    private func render(_ dump: GATTDump) {
        let count = dump.services.count
        print("\(dump.peripheral.name): \(count) service\(count == 1 ? "" : "s")\n")
        for service in dump.services {
            print("Service \(Format.identifier(service.uuid, service.name))")
            for characteristic in service.characteristics {
                var line = "  \(Format.identifier(characteristic.uuid, characteristic.name))"
                if !characteristic.properties.isEmpty {
                    line += "  [\(characteristic.properties.joined(separator: ", "))]"
                }
                if let value = characteristic.value, let data = parseHexBytes(value) {
                    line += " = \(Format.value(data))"
                } else if let failure = characteristic.readFailure {
                    line += " = <read failed: \(failure)>"
                }
                print(line)
                for descriptor in characteristic.descriptors {
                    print("    Descriptor \(Format.identifier(descriptor.uuid, descriptor.name))")
                }
            }
            print("")
        }
    }
}

private struct GATTDump: Encodable {
    struct Peripheral: Encodable {
        let uuid: String
        let name: String
    }
    struct Service: Encodable {
        let uuid: String
        let name: String?
        let characteristics: [Characteristic]
    }
    struct Characteristic: Encodable {
        let uuid: String
        let name: String?
        let properties: [String]
        let value: String?
        let readFailure: String?
        let descriptors: [Descriptor]
    }
    struct Descriptor: Encodable {
        let uuid: String
        let name: String?
    }

    let peripheral: Peripheral
    let services: [Service]
}
