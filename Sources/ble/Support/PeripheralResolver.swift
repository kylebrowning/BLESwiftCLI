import BLESwift
import Foundation

enum PeripheralResolver {
    /// Resolves a user-supplied query to a peripheral identifier.
    ///
    /// A query that parses as a UUID is looked up in the system cache first
    /// (`knownPeripherals`), then hunted for by scanning. Anything else is
    /// treated as a case-insensitive name substring to match while scanning.
    static func resolve(
        _ query: String,
        central: Central,
        services: [ServiceIdentifier]?,
        scanTimeout: Duration
    ) async throws -> PeripheralIdentifier {
        if let uuid = UUID(uuidString: query) {
            if let known = try await central.knownPeripherals(withIdentifiers: [uuid]).first {
                return known
            }
            status("Peripheral is not in the system cache — scanning for it…")
            return try await scanForMatch(central: central, services: services, timeout: scanTimeout) {
                $0.peripheral.uuid == uuid
            }
        }

        status("Scanning for a peripheral named like “\(query)”…")
        return try await scanForMatch(central: central, services: services, timeout: scanTimeout) {
            $0.peripheral.name.localizedCaseInsensitiveContains(query)
                || ($0.advertisement.localName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private static func scanForMatch(
        central: Central,
        services: [ServiceIdentifier]?,
        timeout: Duration,
        where matches: (Discovery) -> Bool
    ) async throws -> PeripheralIdentifier {
        for try await event in await central.scan(services: services, timeout: timeout) {
            if case .discovered(let discovery) = event, matches(discovery) {
                return discovery.peripheral
            }
        }
        throw CLIError("""
        No matching peripheral found within \(timeout.components.seconds)s. \
        Make sure the device is advertising, or try `ble scan` to see what's nearby.
        """)
    }
}
