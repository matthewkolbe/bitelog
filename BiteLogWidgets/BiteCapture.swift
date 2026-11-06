import Foundation

/// `LogBiteIntent` records audio, so the system runs it in the app's process,
/// where the real `BiteCapture` lives. The extension only shows the control.
enum BiteCapture {
    struct Failure: Error, CustomStringConvertible {
        let description = "Log a bite runs in the Bite Log app, not its widget extension."
    }

    static func toggle() async throws { throw Failure() }
}
