import ActivityKit
import AppIntents
import Foundation

// Built into both the app and the widget extension: the control and the Live
// Activity live in the extension, and the intent runs in the app's process
// (it records audio), where `BiteCapture` does the work.

/// The Live Activity shown while a bite is recorded and logged.
nonisolated struct BiteActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case listening, logging, done, failed
        }

        var phase: Phase
        /// When recording started.
        var since: Date
        /// What was logged, or what went wrong.
        var line: String = ""
    }
}

/// Press to start recording what you ate; press again to log it. For the
/// Action Button, Control Center and the Lock Screen.
nonisolated struct LogBiteIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Log a bite"
    static let description = IntentDescription("Press to start recording what you ate, press again to log it.")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        try await BiteCapture.toggle()
        return .result()
    }
}
