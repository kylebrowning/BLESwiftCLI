import ArgumentParser
import BLESwift
import Foundation

struct WriteValue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write structured data to a writable characteristic.",
        discussion: """
        The payload comes from a YAML or JSON file (--payload) describing typed
        fields that are encoded and concatenated — see the README for the
        schema — or inline via --hex or --string for quick one-off writes.

        A payload file can carry its own target (service, characteristic,
        writeType); command-line flags override the file. Before writing, the
        characteristic's advertised properties are checked so a non-writable
        target fails with a clear error instead of a GATT error code.
        """
    )

    @Argument(help: "Peripheral UUID from `ble scan`, or a name substring.")
    var peripheral: String

    @Option(
        name: [.customShort("s"), .customLong("service")],
        help: "Service UUID containing the target characteristic."
    )
    var service: ServiceUUIDArgument?

    @Option(
        name: [.customShort("c"), .customLong("characteristic")],
        help: "UUID of the characteristic to write."
    )
    var characteristic: String?

    @Option(
        name: [.customShort("d"), .customLong("descriptor")],
        help: "Write to this descriptor of the characteristic instead of its value."
    )
    var descriptor: String?

    @Option(
        name: [.customShort("p"), .customLong("payload")],
        help: "Path to a YAML or JSON payload file."
    )
    var payload: String?

    @Option(help: "Inline raw bytes as hex (e.g. 0x01FF) instead of a payload file.")
    var hex: HexBytesArgument?

    @Option(help: "Inline UTF-8 string payload instead of a payload file.")
    var string: String?

    @Flag(help: "Force write-without-response.")
    var withoutResponse = false

    @Option(help: "Await a notification on this characteristic UUID (same service) after the write, and print it.")
    var expectReplyOn: String?

    @Option(help: "Seconds to wait for the reply notification.")
    var replyTimeout: Double = 15

    @Option(help: "Seconds to scan while resolving the peripheral.")
    var scanTimeout: Double = 15

    @Option(name: .shortAndLong, help: "Seconds to allow for connect and write.")
    var timeout: Double = 15

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    @Flag(help: "Encode and print the payload bytes without connecting or writing.")
    var dryRun = false

    func validate() throws {
        let sources = [payload != nil, hex != nil, string != nil].count(where: { $0 })
        guard sources == 1 else {
            throw ValidationError("Provide exactly one of --payload, --hex, or --string.")
        }
        if let characteristic, !ServiceUUIDArgument.isValidBLEUUID(characteristic) {
            throw ValidationError("'\(characteristic)' is not a valid Bluetooth UUID.")
        }
        if let expectReplyOn, !ServiceUUIDArgument.isValidBLEUUID(expectReplyOn) {
            throw ValidationError("'\(expectReplyOn)' is not a valid Bluetooth UUID.")
        }
        if let descriptor {
            guard ServiceUUIDArgument.isValidBLEUUID(descriptor) else {
                throw ValidationError("'\(descriptor)' is not a valid Bluetooth UUID.")
            }
            if withoutResponse {
                throw ValidationError("Descriptor writes are always with-response; --without-response cannot be combined with --descriptor.")
            }
            if expectReplyOn != nil {
                throw ValidationError("--expect-reply-on cannot be combined with --descriptor.")
            }
        }
    }

    func run() async throws {
        let (target, data, fileWriteType) = try resolveTarget()
        if data.isEmpty {
            throw CLIError("The payload is empty — nothing to write.")
        }
        if dryRun {
            print("Target: \(target.service.uuidString) / \(target.uuidString)")
            print("Payload (\(data.count) byte\(data.count == 1 ? "" : "s")): 0x\(Format.hex(data))")
            return
        }

        try await Session.withPeripheral(
            peripheral,
            services: [target.service],
            scanTimeout: scanTimeout,
            connectTimeout: timeout,
            verbose: verbose
        ) { _, connected in
            if let descriptor {
                let identifier = DescriptorIdentifier(uuid: descriptor, characteristic: target)
                try await connected.writeDescriptor(identifier, value: data, timeout: .seconds(timeout))
                print("Wrote \(data.count) byte\(data.count == 1 ? "" : "s") (0x\(Format.hex(data))) to descriptor \(identifier.uuidString).")
                return
            }

            let writeType = try await chooseWriteType(
                connected: connected, target: target, fileWriteType: fileWriteType
            )
            let maxLength = await connected.maximumWriteValueLength(for: writeType)
            if data.count > maxLength {
                status("Warning: payload is \(data.count) bytes but the link allows \(maxLength) per write — the write may fail.")
            }

            if let expectReplyOn {
                let replyCharacteristic = CharacteristicIdentifier(uuid: expectReplyOn, service: target.service)
                status("Writing \(data.count) bytes (0x\(Format.hex(data))) and awaiting reply on \(replyCharacteristic.uuidString)…")
                let reply: Data = try await connected.writeAndAwaitNotification(
                    write: data,
                    to: target,
                    awaitOn: replyCharacteristic,
                    timeout: .seconds(replyTimeout)
                )
                print("Reply: \(reply.count) byte\(reply.count == 1 ? "" : "s"): 0x\(Format.hex(reply))")
            } else {
                try await connected.write(data, to: target, type: writeType, timeout: .seconds(timeout))
                let mode = writeType == .withResponse ? "with response" : "without response"
                print("Wrote \(data.count) byte\(data.count == 1 ? "" : "s") (0x\(Format.hex(data))) \(mode).")
            }
        }
    }

    /// Merges the payload file's target with command-line flags (flags win) and
    /// returns the characteristic, encoded bytes, and the file's write type.
    private func resolveTarget() throws -> (CharacteristicIdentifier, Data, WriteType?) {
        var serviceIdentifier = service?.identifier
        var characteristicUUID = characteristic
        var fileWriteType: WriteType? = nil
        let data: Data

        if let payload {
            let file = try PayloadFile.load(atPath: payload)
            if serviceIdentifier == nil, let fileService = file.service {
                guard ServiceUUIDArgument.isValidBLEUUID(fileService) else {
                    throw CLIError("Payload file service '\(fileService)' is not a valid Bluetooth UUID.")
                }
                serviceIdentifier = ServiceIdentifier(uuid: fileService)
            }
            if characteristicUUID == nil, let fileCharacteristic = file.characteristic {
                guard ServiceUUIDArgument.isValidBLEUUID(fileCharacteristic) else {
                    throw CLIError("Payload file characteristic '\(fileCharacteristic)' is not a valid Bluetooth UUID.")
                }
                characteristicUUID = fileCharacteristic
            }
            fileWriteType = file.writeType.map { $0 == "withoutResponse" ? .withoutResponse : .withResponse }
            data = try file.encodedData()
        } else if let hex {
            data = hex.data
        } else {
            data = Data(string!.utf8)
        }

        guard let serviceIdentifier else {
            throw CLIError("No service UUID — pass --service or set 'service' in the payload file.")
        }
        guard let characteristicUUID else {
            throw CLIError("No characteristic UUID — pass --characteristic or set 'characteristic' in the payload file.")
        }
        return (
            CharacteristicIdentifier(uuid: characteristicUUID, service: serviceIdentifier),
            data,
            fileWriteType
        )
    }

    /// Picks the write type from flags/file/characteristic capabilities, and
    /// rejects characteristics that aren't writable at all.
    private func chooseWriteType(
        connected: Peripheral,
        target: CharacteristicIdentifier,
        fileWriteType: WriteType?
    ) async throws -> WriteType {
        let properties = try await connected.properties(of: target)
        let canWrite = properties.contains(.write)
        let canWriteWithoutResponse = properties.contains(.writeWithoutResponse)
        guard canWrite || canWriteWithoutResponse else {
            throw CLIError("""
            Characteristic \(target.uuidString) is not writable (properties: \
            \(Format.properties(properties))).
            """)
        }

        let requested: WriteType? = withoutResponse ? .withoutResponse : fileWriteType
        switch requested {
        case .some(.withoutResponse) where !canWriteWithoutResponse:
            throw CLIError("Characteristic \(target.uuidString) does not support write-without-response.")
        case .some(.withResponse) where !canWrite:
            throw CLIError("Characteristic \(target.uuidString) only supports write-without-response.")
        case .some(let type):
            return type
        case nil:
            return canWrite ? .withResponse : .withoutResponse
        }
    }
}
