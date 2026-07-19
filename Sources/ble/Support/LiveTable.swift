import Darwin
import Foundation

/// In-place terminal table for live scan mode: each render moves the cursor back to the
/// top of the previously drawn region and redraws, so the table updates rather than
/// scrolls. Autowrap is disabled while active (long rows clip at the right edge instead
/// of corrupting the cursor-up arithmetic) and the cursor is hidden; ``end()`` restores
/// both.
struct LiveTable {
    private var renderedLines = 0
    private var lastRender: ContinuousClock.Instant?

    /// Rows the terminal can show beyond the header/footer chrome.
    static func visibleRowBudget() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 4 else { return 40 }
        return Int(size.ws_row) - 4
    }

    mutating func begin() {
        write("\u{1B}[?25l\u{1B}[?7l")
    }

    /// Redraws the region. Renders are throttled to ~7 Hz so bursts of advertisements
    /// don't flicker; pass `force: true` for the final frame so the last state sticks.
    mutating func render(_ lines: [String], force: Bool = false) {
        let now = ContinuousClock.now
        if !force, let lastRender, now - lastRender < .milliseconds(150) { return }
        var frame = renderedLines > 0 ? "\u{1B}[\(renderedLines)A" : ""
        for line in lines {
            frame += "\u{1B}[2K\(line)\n"
        }
        frame += "\u{1B}[0J"
        write(frame)
        renderedLines = lines.count
        lastRender = now
    }

    func end() {
        write("\u{1B}[?7h\u{1B}[?25h")
    }

    private func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }
}

/// Exponentially smoothed RSSI used as the live table's sort key, so ordering tracks
/// sustained signal changes instead of reshuffling on every fluctuation. The raw RSSI
/// is still what gets displayed.
func smoothedRSSI(previous: Double?, new: Int) -> Double {
    guard let previous else { return Double(new) }
    return previous * 0.7 + Double(new) * 0.3
}
