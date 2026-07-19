import Dispatch
import Foundation

enum Interrupt {
    /// Suspends until the user presses Ctrl-C, or until the surrounding task is
    /// cancelled. Once the first Ctrl-C is consumed the default SIGINT disposition
    /// is restored, so a second Ctrl-C terminates the process immediately.
    static func wait() async {
        let signals = AsyncStream<Void> { continuation in
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler { continuation.yield() }
            continuation.onTermination = { _ in
                source.cancel()
                signal(SIGINT, SIG_DFL)
            }
            source.resume()
        }
        for await _ in signals { break }
    }
}
