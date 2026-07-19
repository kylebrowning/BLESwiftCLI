import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch
import Foundation
import Testing
@testable import ble

/// Tests against BLESwift's scriptable fakes — no hardware, no radio.
@Suite("Peripheral resolution")
struct ResolverTests {

    private func makeRig(_ label: String) -> (central: Central, fake: FakeCentral, queue: DispatchSerialQueue) {
        let queue = DispatchSerialQueue(label: "bleTests.\(label)")
        let fake = FakeCentral(queue: queue)
        let central = Central(backend: fake, queue: queue)
        fake.simulateStateChange(.poweredOn)
        return (central, fake, queue)
    }

    private func waitForScan(on fake: FakeCentral) async throws {
        while await fake.onQueue({ fake.scanCallCount }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a cached UUID resolves without scanning")
    func cachedUUID() async throws {
        let (central, fake, queue) = makeRig("cachedUUID")
        let device = FakePeripheral(queue: queue)
        await fake.onQueue { fake.retrievablePeripherals[device.identifier] = device }

        let id = try await PeripheralResolver.resolve(
            device.identifier.uuidString, central: central, services: nil, scanTimeout: .seconds(1)
        )
        #expect(id.uuid == device.identifier)
        #expect(await fake.onQueue { fake.scanCallCount } == 0)
    }

    @Test("an uncached UUID is hunted for by scanning")
    func uncachedUUIDScans() async throws {
        let (central, fake, _) = makeRig("uncachedUUID")
        let target = UUID()

        let resolution = Task {
            try await PeripheralResolver.resolve(
                target.uuidString, central: central, services: nil, scanTimeout: .seconds(5)
            )
        }
        try await waitForScan(on: fake)
        fake.simulateDiscovery(
            peripheral: PeripheralIdentifier(uuid: UUID(), name: "Decoy"),
            advertisement: AdvertisementData(),
            rssi: -40
        )
        fake.simulateDiscovery(
            peripheral: PeripheralIdentifier(uuid: target, name: "Widget"),
            advertisement: AdvertisementData(),
            rssi: -50
        )

        let id = try await resolution.value
        #expect(id.uuid == target)
        #expect(id.name == "Widget")
    }

    @Test("a non-UUID query matches by advertised name, case-insensitively")
    func nameSubstring() async throws {
        let (central, fake, _) = makeRig("nameSubstring")
        let target = UUID()

        let resolution = Task {
            try await PeripheralResolver.resolve(
                "widg", central: central, services: nil, scanTimeout: .seconds(5)
            )
        }
        try await waitForScan(on: fake)
        fake.simulateDiscovery(
            peripheral: PeripheralIdentifier(uuid: target, name: nil),
            advertisement: AdvertisementData(localName: "My WIDGET"),
            rssi: -50
        )

        let id = try await resolution.value
        #expect(id.uuid == target)
    }

    @Test("no match within the scan timeout throws a CLIError")
    func timeoutThrows() async throws {
        let (central, fake, _) = makeRig("timeoutThrows")

        let resolution = Task {
            try await PeripheralResolver.resolve(
                "nothing-advertises-this", central: central, services: nil,
                scanTimeout: .milliseconds(200)
            )
        }
        try await waitForScan(on: fake)
        fake.simulateDiscovery(
            peripheral: PeripheralIdentifier(uuid: UUID(), name: "Unrelated"),
            advertisement: AdvertisementData(),
            rssi: -50
        )

        await #expect(throws: CLIError.self) { try await resolution.value }
    }
}

@Suite("Radio readiness")
struct RadioTests {

    @Test("poweredOn returns immediately")
    func poweredOn() async throws {
        let queue = DispatchSerialQueue(label: "bleTests.radioPoweredOn")
        let fake = FakeCentral(queue: queue)
        let central = Central(backend: fake, queue: queue)
        fake.simulateStateChange(.poweredOn)
        try await Radio.waitUntilReady(central, timeout: .seconds(1))
    }

    @Test("unauthorized fails with an actionable error")
    func unauthorized() async {
        let queue = DispatchSerialQueue(label: "bleTests.radioUnauthorized")
        let fake = FakeCentral(queue: queue)
        let central = Central(backend: fake, queue: queue)
        fake.simulateStateChange(.unauthorized)
        await #expect(throws: CLIError.self) {
            try await Radio.waitUntilReady(central, timeout: .seconds(1))
        }
    }

    @Test("a late power-on is waited for")
    func latePowerOn() async throws {
        let queue = DispatchSerialQueue(label: "bleTests.radioLatePowerOn")
        let fake = FakeCentral(queue: queue)
        let central = Central(backend: fake, queue: queue)
        fake.simulateStateChange(.poweredOff)

        let waiting = Task { try await Radio.waitUntilReady(central, timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        fake.simulateStateChange(.poweredOn)
        try await waiting.value
    }

    @Test("never powering on times out with a CLIError")
    func neverPowersOn() async {
        let queue = DispatchSerialQueue(label: "bleTests.radioNeverOn")
        let fake = FakeCentral(queue: queue)
        let central = Central(backend: fake, queue: queue)
        await #expect(throws: CLIError.self) {
            try await Radio.waitUntilReady(central, timeout: .milliseconds(200))
        }
    }
}
