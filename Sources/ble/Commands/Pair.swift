import ArgumentParser
import BLESwift
import Foundation

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Trigger the macOS pairing flow for a peripheral.",
        discussion: """
        CoreBluetooth has no explicit "pair" call. Pairing happens when you access
        a characteristic that requires encryption or authentication: macOS shows
        the pairing dialog, and once you approve it the pending operation
        completes and the devices are bonded.

        This command connects and reads the given characteristic (or writes to it
        with --write). Point it at a protected characteristic on your device. If
        the characteristic is unprotected the operation still succeeds, but no
        pairing is required or performed.

        To unpair, remove the device in System Settings > Bluetooth.
        """
    )

    @Argument(help: "Peripheral UUID from `ble scan`, or a name substring.")
    var peripheral: String

    @Option(
        name: [.customShort("s"), .customLong("service")],
        help: "Service UUID containing the protected characteristic."
    )
    var service: ServiceUUIDArgument

    @Option(
        name: [.customShort("c"), .customLong("characteristic")],
        help: "UUID of the protected characteristic to access."
    )
    var characteristic: String

    @Option(help: "Write these hex bytes (e.g. 0x01FF) instead of reading.")
    var write: HexBytesArgument?

    @Flag(help: "Use write-without-response for the --write payload.")
    var withoutResponse = false

    @Option(help: "Seconds to scan while resolving the peripheral.")
    var scanTimeout: Double = 15

    @Option(name: .shortAndLong, help: "Seconds to allow for the operation, including your time to approve the pairing dialog.")
    var timeout: Double = 60

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    func validate() throws {
        guard ServiceUUIDArgument.isValidBLEUUID(characteristic) else {
            throw ValidationError("'\(characteristic)' is not a valid Bluetooth UUID.")
        }
        if withoutResponse && write == nil {
            throw ValidationError("--without-response requires --write.")
        }
    }

    func run() async throws {
        try await Session.withPeripheral(
            peripheral,
            services: [service.identifier],
            scanTimeout: scanTimeout,
            connectTimeout: timeout,
            verbose: verbose
        ) { _, connected in
            let target = CharacteristicIdentifier(uuid: characteristic, service: service.identifier)
            status("Accessing characteristic \(target.uuidString) — approve the pairing dialog if one appears…")
            do {
                if let write {
                    try await connected.write(
                        write.data,
                        to: target,
                        type: withoutResponse ? .withoutResponse : .withResponse,
                        timeout: .seconds(timeout)
                    )
                    print("Wrote \(write.data.count) byte\(write.data.count == 1 ? "" : "s").")
                } else {
                    let value: Data = try await connected.read(from: target, timeout: .seconds(timeout))
                    print("Read \(value.count) byte\(value.count == 1 ? "" : "s"): 0x\(Format.hex(value))")
                }
            } catch {
                throw CLIError("""
                Pairing access failed: \(error.localizedDescription)
                If you dismissed the pairing dialog, run the command again. If the device \
                was previously paired with stale keys, remove it in System Settings > \
                Bluetooth and retry.
                """)
            }
            print("Success. If a pairing dialog appeared and you approved it, the devices are now bonded.")
        }
    }
}
