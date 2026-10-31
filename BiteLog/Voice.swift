import AVFoundation
import Foundation
import Observation
import Speech

/// Speech to text on the phone (Apple's SpeechAnalyzer): free, private, works
/// offline once the language's model is installed.
enum Transcriber {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let locale = Locale(identifier: "en-US")

    /// Which of Apple's models this device runs: SpeechTranscriber (the newer,
    /// general one) where the device supports it, else DictationTranscriber,
    /// which Apple provides for devices without it (and the simulator).
    static var engine: String { SpeechTranscriber.isAvailable ? "SpeechTranscriber" : "DictationTranscriber" }

    /// The words in a recording. Installs the speech model the first time.
    static func transcribe(_ file: URL) async throws -> String {
        let audio = try AVAudioFile(forReading: file)
        if SpeechTranscriber.isAvailable {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw Failure(description: "this phone has no on-device speech model for English")
            }
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            try await install(module)
            async let words = module.results.reduce(into: "") { $0 += String($1.text.characters) }
            try await analyze(audio, with: module)
            return try await words.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure(description: "this phone has no on-device dictation model for English")
        }
        let module = DictationTranscriber(locale: locale, preset: .shortDictation)
        try await install(module)
        async let words = module.results.reduce(into: "") { $0 += String($1.text.characters) }
        try await analyze(audio, with: module)
        return try await words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func install(_ module: any SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// Feeds the whole recording to the model, converted to the format it asks for.
    private static func analyze(_ audio: AVAudioFile, with module: any SpeechModule) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            #if targetEnvironment(simulator)
            throw Failure(description: "the iOS Simulator can't run on-device speech to text; voice works on an iPhone")
            #else
            throw Failure(description: "the speech model accepts no audio format")
            #endif
        }
        let buffer = try convert(audio, to: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        if let last = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }

    private static func convert(_ file: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(file.length)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Failure(description: "couldn't read the recording")
        }
        try file.read(into: source)
        if file.processingFormat == format { return source }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(
                  (Double(frames) * format.sampleRate / file.processingFormat.sampleRate).rounded(.up)) + 1024) else {
            throw Failure(description: "can't convert the recording to \(format)")
        }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if given { state.pointee = .endOfStream; return nil }
            given = true
            state.pointee = .haveData
            return source
        }
        if status == .error { throw error ?? Failure(description: "converting the recording failed") }
        return out
    }
}

/// Records the microphone to a 16 kHz mono WAV while a button is held.
@Observable
final class Recorder {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case denied
    }

    private(set) var state = State.idle
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var file: URL?

    var isRecording: Bool { if case .recording = state { true } else { false } }

    func start() async throws {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).wav")
        let r = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard r.record() else { throw Transcriber.Failure(description: "the microphone didn't start") }
        recorder = r
        file = url
        state = .recording(since: Date())
    }

    /// The recording, or nil when it was too short to hold words (a tap).
    func stop() -> URL? {
        guard case .recording(let since) = state, let r = recorder, let url = file else { return nil }
        r.stop()
        recorder = nil
        file = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard Date().timeIntervalSince(since) >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }
}
