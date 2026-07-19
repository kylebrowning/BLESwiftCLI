import Testing
@testable import ble

@Suite("Live scan sorting")
struct LiveTableTests {
    @Test("First sighting uses the raw RSSI as the sort key")
    func firstSighting() {
        #expect(smoothedRSSI(previous: nil, new: -60) == -60)
    }

    @Test("Subsequent readings move the sort key gradually (70/30 blend)")
    func smoothing() {
        let blended = smoothedRSSI(previous: -60, new: -90)
        #expect(blended == -69)
        // A single outlier can't leapfrog a sustained stronger signal.
        #expect(blended > -75)
    }

    @Test("Repeated readings at a new level converge to it")
    func convergence() {
        var key = smoothedRSSI(previous: nil, new: -60)
        for _ in 0..<20 { key = smoothedRSSI(previous: key, new: -40) }
        #expect(abs(key - -40) < 1)
    }
}
