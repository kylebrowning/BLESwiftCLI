import ArgumentParser
import BLESwift
import Foundation

struct L2CAP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "l2cap",
        abstract: "Open an L2CAP channel and stream its data.",
        discussion: """
        Opens a connection-oriented L2CAP channel on the given PSM, optionally
        sends an initial payload, then streams incoming data until Ctrl-C or
        the channel closes. Incoming data prints as timestamped hex lines;
        --raw writes the raw bytes to stdout instead, for piping.
        """
    )

    @Argument(help: "Peripheral UUID from `ble scan`, or a name substring.")
    var peripheral: String

    @Option(help: "The channel's PSM, decimal or hex (e.g. 128 or 0x0080).")
    var psm: PSMArgument

    @Option(help: "Send these hex bytes once the channel opens.")
    var sendHex: HexBytesArgument?

    @Option(help: "Send this UTF-8 string once the channel opens.")
    var sendString: String?

    @Flag(help: "Write incoming bytes raw to stdout instead of hex lines.")
    var raw = false

    @Option(help: "Seconds to scan while resolving the peripheral.")
    var scanTimeout: Double = 15

    @Option(name: .shortAndLong, help: "Seconds to wait for connect and channel open.")
    var timeout: Double = 15

    @Flag(name: .shortAndLong, help: "Log BLESwift internals to stderr.")
    var verbose = false

    func validate() throws {
        if sendHex != nil && sendString != nil {
            throw ValidationError("Provide at most one of --send-hex and --send-string.")
        }
    }

    func run() async throws {
        try await Session.withPeripheral(
            peripheral,
            services: nil,
            scanTimeout: scanTimeout,
            connectTimeout: timeout,
            verbose: verbose
        ) { _, connected in
            let channel: L2CAPChannel
            do {
                channel = try await connected.openL2CAPChannel(psm: psm.value, timeout: .seconds(timeout))
            } catch let error as BLESwiftError where error == .timedOut {
                throw CLIError("""
                Timed out opening an L2CAP channel on PSM \(psm.value). Verify the \
                peripheral actually listens on this PSM — devices usually publish it in a \
                vendor characteristic, or in their firmware docs.
                """)
            }
            status("Channel open on PSM \(psm.value) — press Ctrl-C to close.")

            if let outgoing = sendHex?.data ?? sendString.map({ Data($0.utf8) }) {
                try await channel.write(outgoing)
                status("Sent \(outgoing.count) byte\(outgoing.count == 1 ? "" : "s").")
            }

            enum Outcome {
                case finished(Error?)
                case interrupted
            }
            let emitRaw = raw
            let outcome = await withTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    let clock = DateFormatter()
                    clock.dateFormat = "HH:mm:ss.SSS"
                    do {
                        for try await chunk in channel.incomingData {
                            if emitRaw {
                                FileHandle.standardOutput.write(chunk)
                            } else {
                                print("\(clock.string(from: Date()))  \(Format.value(chunk))")
                                fflush(stdout)
                            }
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
            await channel.close()

            switch outcome {
            case .interrupted:
                status("Channel closed.")
            case .finished(let error):
                if let error {
                    throw CLIError("Channel ended: \(error.localizedDescription)")
                }
                status("Channel closed by the peripheral.")
            }
        }
    }
}

struct PSMArgument: ExpressibleByArgument {
    let value: L2CAPPSM

    init?(argument: String) {
        let raw: UInt16?
        if argument.lowercased().hasPrefix("0x") {
            raw = UInt16(argument.dropFirst(2), radix: 16)
        } else {
            raw = UInt16(argument)
        }
        guard let raw else { return nil }
        value = L2CAPPSM(raw)
    }
}
