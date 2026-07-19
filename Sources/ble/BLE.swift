import ArgumentParser

@main
struct BLE: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ble",
        abstract: "Scan, connect, and pair with Bluetooth Low Energy peripherals.",
        discussion: """
        Built on BLESwift (https://github.com/kylebrowning/BLESwift).

        The first run may prompt for Bluetooth access; grant it to your terminal
        app under System Settings > Privacy & Security > Bluetooth.
        """,
        version: "1.0.0",
        subcommands: [Scan.self, Connect.self, Pair.self, Inspect.self, ReadValue.self, WriteValue.self, L2CAP.self]
    )
}
