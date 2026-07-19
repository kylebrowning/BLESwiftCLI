import Foundation

/// A user-facing failure. ArgumentParser prints `errorDescription` and exits non-zero.
struct CLIError: Error, LocalizedError, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? { description }
}
