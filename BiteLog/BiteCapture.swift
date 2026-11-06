import ActivityKit
import AVFoundation
import Foundation

/// What `LogBiteIntent` does, in the app's process: the first press starts
/// recording and a Live Activity that shows it's listening; the next press
/// logs it and shows what was logged.
enum BiteCapture {
    /// A recording nobody stops is logged after this long.
    static let maxLength: Duration = .seconds(15)

    private static let recorder = Recorder()
    /// The Live Activity's id; activities aren't Sendable, so they're looked
    /// up by id off the main actor.
    private static var activity: String?
    private static var since = Date()
    private static var limit: Task<Void, Never>?

    struct Failure: Error, CustomStringConvertible, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    static func toggle() async throws {
        if recorder.isRecording { try await finish() } else { try await start() }
    }

    private static func start() async throws {
        let model = try AppModel.shared.get()
        guard !model.profiles.profiles.isEmpty else { throw Failure(description: "Open Bite Log and set up a model first.") }
        // the permission prompt can't show from the background
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw Failure(description: "Open Bite Log and allow the microphone first.")
        }
        // the Live Activity comes first: without one the system stops the recording
        since = Date()
        activity = try Activity.request(attributes: BiteActivity(),
                                        content: .init(state: .init(phase: .listening, since: since), staleDate: nil)).id
        do {
            try await recorder.start()
        } catch {
            if let id = activity { await update(id, .init(phase: .failed, since: since, line: "\(error)"), ending: true) }
            activity = nil
            throw error
        }
        limit = Task {
            try? await Task.sleep(for: maxLength)
            if !Task.isCancelled, recorder.isRecording { try? await finish() }
        }
    }

    private static func finish() async throws {
        limit?.cancel()
        limit = nil
        // this bite's activity: a press while it logs starts the next one
        let id = activity, since = since
        activity = nil
        func end(_ phase: BiteActivity.ContentState.Phase, _ line: String) async {
            if let id { await update(id, .init(phase: phase, since: since, line: line), ending: true) }
        }
        guard let url = recorder.stop() else {
            await end(.failed, "Too short. Press, say what you ate, then press again.")
            return
        }
        if let id { await update(id, .init(phase: .logging, since: since, line: "Logging…")) }
        do {
            let model = try AppModel.shared.get()
            let entry = try model.log.addEntry(audio: try Media.adopt(url, ext: "wav"))
            model.logger.kick()
            await model.logger.settled()
            let (phase, line) = outcome(try model.log.entry(entry))
            await end(phase, line)
        } catch {
            await end(.failed, "Couldn't save it: \(error)")
            throw error
        }
    }

    static func outcome(_ e: LogDB.Entry?) -> (BiteActivity.ContentState.Phase, String) {
        guard let e else { return (.failed, "The entry was deleted.") }
        switch e.status {
        case .done: return (.done, "\(e.what) · \(Int(e.kcal.rounded())) kcal")
        case .nothing: return (.failed, "Heard nothing.")
        case .error: return (.failed, e.error ?? "Couldn't log it.")
        default: return (.done, "Saved. It logs when a model is reachable.")
        }
    }

    nonisolated private static func update(_ id: String, _ state: BiteActivity.ContentState, ending: Bool = false) async {
        for a in Activity<BiteActivity>.activities where a.id == id {
            if ending {
                await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 8))
            } else {
                await a.update(.init(state: state, staleDate: nil))
            }
        }
    }
}
