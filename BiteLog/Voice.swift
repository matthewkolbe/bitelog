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

    /// What the recognizer heard, and the other readings it weighed for the
    /// same sound: it spells by sound, so "one pair" may also be "one pear".
    nonisolated struct Transcript: Equatable {
        var text: String
        var alternatives: [String] = []
    }

    /// The words in a recording. Installs the speech model the first time.
    static func transcribe(_ file: URL) async throws -> Transcript {
        let audio = try AVAudioFile(forReading: file)
        if SpeechTranscriber.isAvailable {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw Failure(description: "this phone has no on-device speech model for English")
            }
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: [.alternativeTranscriptions], attributeOptions: [])
            try await install(module)
            async let parts = module.results.reduce(into: [Part]()) { $0.append(Part($1.text, $1.alternatives)) }
            try await analyze(audio, with: module)
            return join(try await parts)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure(description: "this phone has no on-device dictation model for English")
        }
        var preset = DictationTranscriber.Preset.shortDictation
        preset.reportingOptions.insert(.alternativeTranscriptions)
        let module = DictationTranscriber(locale: locale, preset: preset)
        try await install(module)
        async let parts = module.results.reduce(into: [Part]()) { $0.append(Part($1.text, $1.alternatives)) }
        try await analyze(audio, with: module)
        return join(try await parts)
    }

    /// One result from the recognizer: a stretch of the recording, with the
    /// other readings it considered for that stretch.
    nonisolated struct Part {
        let text: String
        let alternatives: [String]
        init(_ text: AttributedString, _ alternatives: [AttributedString]) {
            self.text = String(text.characters)
            self.alternatives = alternatives.map { String($0.characters) }
        }
    }

    /// The parts' words in order, and the whole-recording readings you get by
    /// swapping one part for one of its alternatives. Only readings with
    /// different words count: most of what the recognizer offers differs in
    /// punctuation or case alone ("18 grams of grapes?").
    nonisolated static func join(_ parts: [Part]) -> Transcript {
        let text = parts.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var alternatives: [String] = [], seen: Set<String> = [words(text)]
        for (i, part) in parts.enumerated() {
            for alt in part.alternatives {
                var pieces = parts.map(\.text)
                pieces[i] = alt
                let whole = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if seen.insert(words(whole)).inserted { alternatives.append(whole) }
            }
        }
        return Transcript(text: text, alternatives: alternatives)
    }

    /// The words alone: lowercased, without punctuation.
    private nonisolated static func words(_ s: String) -> String {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "%") }.joined(separator: " ")
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
