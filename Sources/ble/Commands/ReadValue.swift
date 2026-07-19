import ArgumentParser
import BLESwift
import Foundation

struct ReadValue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a characteristic or descriptor, or stream its notifications.",
        discussion: """
        By default performs a single read and prints the value as hex with
        friendly interpretations (unsigned integer, UTF-8 text). With --notify
        it subscribes instead and streams values until Ctrl-C (or --count
        values). With --descriptor it reads that descriptor of the
        characteristic (e.g. 2901, the User Description).
        """
    )

    @Argument(help: "Peripheral UUID from `ble scan`, or a name substring.")
    var peripheral: String

    @Option(
        name: [.customShort("s"), .customLong("service")],
        help: "Service UUID containing the characteristic."
    )
    var service: ServiceUUIDArgument

    @Option(
        name: [.customShort("c"), .customLong("characteristic")],
        help: "UUID of the characteristic to read."
    )
    var characteristic: String

    @Option(
        name: [.customShort("d"), .customLong("descriptor")],
        help: "Read this descriptor of the characteristic instead of its value."
    )
    var descriptor: String?

    @Flag(help: "Subscribe to notifications and stream values instead of reading once.")
    var notify = false

    @Option(help: "With --notify, stop after this many values.")
    var count: Int?

    @Option(help: "Seconds to scan while resolving the peripheral.")
    var scanTimeout: Double = 15

    @Option(name: .shortAndLong, help: "Seconds to allow for connect and read.")
    var timeout: Double = 15

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    func validate() throws {
        guard ServiceUUIDArgument.isValidBLEUUID(characteristic) else {
            throw ValidationError("'\(characteristic)' is not a valid Bluetooth UUID.")
        }
        if let descriptor {
            guard ServiceUUIDArgument.isValidBLEUUID(descriptor) else {
                throw ValidationError("'\(descriptor)' is not a valid Bluetooth UUID.")
            }
            if notify {
                throw ValidationError("--descriptor and --notify cannot be combined.")
            }
        }
        if count != nil && !notify {
            throw ValidationError("--count requires --notify.")
        }
        if let count, count < 1 {
            throw ValidationError("--count must be at least 1.")
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
            if let descriptor {
                let identifier = DescriptorIdentifier(uuid: descriptor, characteristic: target)
                let value = try await connected.readDescriptor(identifier, timeout: .seconds(timeout))
                print("Descriptor \(identifier.uuidString): \(Format.value(value))")
            } else if notify {
                try await streamNotifications(from: connected, characteristic: target)
            } else {
                let value: Data = try await connected.read(from: target, timeout: .seconds(timeout))
                print(Format.value(value))
            }
        }
    }

    private func streamNotifications(
        from connected: Peripheral,
        characteristic target: CharacteristicIdentifier
    ) async throws {
        let properties = try await connected.properties(of: target)
        guard properties.contains(.notify) || properties.contains(.indicate) else {
            throw CLIError("""
            Characteristic \(target.uuidString) does not support notifications \
            (properties: \(Format.properties(properties))).
            """)
        }

        status("Subscribed to \(target.uuidString) — press Ctrl-C to stop.")
        let values: AsyncThrowingStream<Data, Error> = connected.notifications(for: target)
        let limit = count

        enum Outcome {
            case finished(Error?)
            case interrupted
        }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let clock = DateFormatter()
                clock.dateFormat = "HH:mm:ss.SSS"
                var received = 0
                do {
                    for try await value in values {
                        print("\(clock.string(from: Date()))  \(Format.value(value))")
                        fflush(stdout)
                        received += 1
                        if let limit, received >= limit { return .finished(nil) }
                    }
                    return .finished(nil)
                } catch {
                    return .finished(error)
                }
            }
            group.addTask {
                await Interrupt.wait()
                return .interrupted
            }
            let first = await group.next() ?? .finished(nil)
            group.cancelAll()
            return first
        }

        if case .finished(let error) = outcome, let error {
            throw CLIError("Notification stream ended: \(error.localizedDescription)")
        }
    }
}
