import BLESwift
import Foundation
import Logging

enum Radio {
    /// Creates a `Central` that is quiet unless `verbose`, in which case
    /// BLESwift's internal logs go to stderr (keeping stdout parseable).
    static func makeCentral(verbose: Bool) -> Central {
        let logger = verbose
            ? Logger(label: "BLESwift", factory: { StreamLogHandler.standardError(label: $0) })
            : Logger(label: "BLESwift", factory: { _ in SwiftLogNoOpLogHandler() })
        return Central(configuration: Configuration(logger: logger))
    }

    /// Waits for the radio to reach `.poweredOn`, translating the terminal states
    /// into actionable errors.
    static func waitUntilReady(_ central: Central, timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var announcedPoweredOff = false
                for await state in await central.stateEvents() {
                    switch state {
                    case .poweredOn:
                        return
                    case .unauthorized:
                        throw CLIError("""
                        Bluetooth access is denied. Grant it to your terminal app under \
                        System Settings > Privacy & Security > Bluetooth, then run again.
                        """)
                    case .unsupported:
                        throw CLIError("Bluetooth Low Energy is not supported on this machine.")
                    case .poweredOff:
                        if !announcedPoweredOff {
                            announcedPoweredOff = true
                            status("Bluetooth is powered off — waiting for it to come on…")
                        }
                    case .unknown, .resetting:
                        break
                    }
                }
                throw CLIError("Bluetooth state stream ended unexpectedly.")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CLIError("Timed out waiting for Bluetooth to power on.")
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
