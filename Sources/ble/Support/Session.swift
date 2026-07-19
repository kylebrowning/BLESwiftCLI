import BLESwift
import Foundation

/// Prints a progress/status message to stderr, keeping stdout clean for data
/// (scan lines, values, JSON) so the tool pipes well.
func status(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

enum Session {
    /// The shared command preamble: radio up, peripheral resolved, connected —
    /// then runs `body` and disconnects afterwards, success or failure.
    static func withPeripheral<T>(
        _ query: String,
        services: [ServiceIdentifier]?,
        scanTimeout: Double,
        connectTimeout: Double,
        verbose: Bool,
        body: (Central, Peripheral) async throws -> T
    ) async throws -> T {
        let central = Radio.makeCentral(verbose: verbose)
        try await Radio.waitUntilReady(central)
        let id = try await PeripheralResolver.resolve(
            query, central: central, services: services, scanTimeout: .seconds(scanTimeout)
        )
        status("Connecting to \(id.name) (\(id.uuid))…")
        let peripheral = try await central.connect(id, timeout: .seconds(connectTimeout))
        do {
            let result = try await body(central, peripheral)
            try? await peripheral.disconnect()
            return result
        } catch {
            try? await peripheral.disconnect()
            throw error
        }
    }
}
