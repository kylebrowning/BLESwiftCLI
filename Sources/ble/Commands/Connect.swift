import ArgumentParser
import BLESwift
import Foundation

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect to a peripheral and hold the connection open.",
        discussion: """
        The peripheral can be given as a UUID (from `ble scan`) or as a name
        substring to match while scanning. The connection stays open until you
        press Ctrl-C — a BLE link only lives as long as the process holding it.
        """
    )

    @Argument(help: "Peripheral UUID from `ble scan`, or a name substring.")
    var peripheral: String

    @Option(
        name: [.customShort("s"), .customLong("service")],
        help: "Narrow the resolution scan to this service UUID. Repeatable."
    )
    var services: [ServiceUUIDArgument] = []

    @Option(help: "Seconds to scan while resolving the peripheral.")
    var scanTimeout: Double = 15

    @Option(name: .shortAndLong, help: "Seconds to wait for the connection to establish.")
    var timeout: Double = 15

    @Flag(help: "Automatically reconnect after unexpected disconnects.")
    var reconnect = false

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    func run() async throws {
        let central = Radio.makeCentral(verbose: verbose)
        try await Radio.waitUntilReady(central)

        let serviceFilter = services.isEmpty ? nil : services.map(\.identifier)
        let id = try await PeripheralResolver.resolve(
            peripheral, central: central, services: serviceFilter, scanTimeout: .seconds(scanTimeout)
        )

        status("Connecting to \(id.name) (\(id.uuid))…")
        let connected = try await central.connect(
            id,
            timeout: .seconds(timeout),
            reconnect: reconnect ? .always() : .never
        )
        if let rssi = try? await connected.readRSSI(timeout: .seconds(5)) {
            print("Connected (\(rssi) dBm).")
        } else {
            print("Connected.")
        }
        status("Holding connection open — press Ctrl-C to disconnect.")

        let outcome = await holdOpen(central: central, id: id)
        switch outcome {
        case .interrupted:
            print("Disconnecting…")
            try? await connected.disconnect()
            print("Disconnected.")
        case .connectionEnded(let error):
            if let error {
                throw CLIError("Connection lost: \(error.localizedDescription)")
            }
            print("Peripheral disconnected.")
        }
    }

    private enum HoldOutcome {
        case interrupted
        case connectionEnded(Error?)
    }

    /// Streams lifecycle events for the peripheral until Ctrl-C or a terminal disconnect.
    private func holdOpen(central: Central, id: PeripheralIdentifier) async -> HoldOutcome {
        let events = await central.connectionEvents()
        return await withTaskGroup(of: HoldOutcome.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .disconnected(let eventID, error: let error, willReconnect: let willReconnect) where eventID == id:
                        print(Format.connectionEventLine(event))
                        if !willReconnect {
                            return .connectionEnded(error)
                        }
                    default:
                        if event.peripheralID == id {
                            print(Format.connectionEventLine(event))
                        }
                    }
                }
                return .connectionEnded(nil)
            }
            group.addTask {
                await Interrupt.wait()
                return .interrupted
            }
            let first = await group.next() ?? .connectionEnded(nil)
            group.cancelAll()
            return first
        }
    }
}

private extension ConnectionEvent {
    var peripheralID: PeripheralIdentifier {
        switch self {
        case .connecting(let id), .connected(let id):
            id
        case .reconnecting(let id, attempt: _):
            id
        case .disconnected(let id, error: _, willReconnect: _):
            id
        }
    }
}
