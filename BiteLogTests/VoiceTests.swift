import Foundation
import Testing
@testable import BiteLog

/// Apple's on-device speech to text on the web app's own recordings, next to
/// what Parakeet heard for them, and what Apple also heard (its alternative
/// readings). Runs on an iPhone, not the Simulator (it has no working speech
/// model). Only when the recordings are in the test bundle:
///   mkdir -p BiteLogTests/Recordings/media; copy calories.db and its media/*.wav there; xcodegen
///   xcodebuild … -destination 'platform=iOS,id=<phone>' -only-testing 'BiteLogTests/VoiceTests' test
/// Each row is printed, and the table is written to the app's Documents/stt.tsv:
///   xcrun devicectl device copy from --device <phone> --domain-type appDataContainer \
///     --domain-identifier app.bitelog.ios --source Documents/stt.tsv --destination stt.tsv
@MainActor
struct VoiceTests {
    nonisolated static let recordings = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?
        .url(forResource: "Recordings", withExtension: nil)

    #if targetEnvironment(simulator)
    nonisolated static let onPhone = false
    #else
    nonisolated static let onPhone = true
    #endif

    @Test(.enabled(if: recordings != nil && onPhone), .timeLimit(.minutes(20)))
    func compareWithParakeet() async throws {
        let dir = try #require(Self.recordings)
        let db = try SQLite(path: dir.appendingPathComponent("calories.db").path, readOnly: true)
        let rows = try db.rows("SELECT audio, transcript FROM entry WHERE audio IS NOT NULL AND transcript IS NOT NULL ORDER BY id")
        var out = "file\tparakeet\tapple\tapple also heard\n"
        var heard = 0, withAlternatives = 0
        for r in rows {
            let name = r["audio"]!.string!, parakeet = r["transcript"]!.string!
            let file = dir.appendingPathComponent("media").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let apple = try await Transcriber.transcribe(file)
            if !apple.text.isEmpty { heard += 1 }
            if !apple.alternatives.isEmpty { withAlternatives += 1 }
            let line = "\(name)\t\(parakeet)\t\(apple.text)\t\(apple.alternatives.joined(separator: " | "))"
            print("STT\t" + line)
            out += line + "\n"
        }
        print("STT\theard \(heard) of \(rows.count), with alternatives \(withAlternatives), engine \(Transcriber.engine)")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try out.write(to: docs.appendingPathComponent("stt.tsv"), atomically: true, encoding: .utf8)
        #expect(heard > 0)
    }
}
/// How the recognizer's per-stretch alternatives become whole readings.
@MainActor
struct TranscriptJoinTests {
    private func part(_ t: String, _ alts: [String] = []) -> Transcriber.Part {
        .init(AttributedString(t), alts.map { AttributedString($0) })
    }

    @Test func oneStretch() {
        let t = Transcriber.join([part("One pair.", ["One pear.", "One pair."])])
        #expect(t == .init(text: "One pair.", alternatives: ["One pear."]))
    }

    @Test func punctuationAndCaseAreNotOtherReadings() {
        let t = Transcriber.join([part("18 grams of grapes.", ["18 grams of grapes?", "18 grams of Grapes",
                                                               "18 grams, of grapes.", "18 g of grapes.", "18 g of grapes?"])])
        #expect(t == .init(text: "18 grams of grapes.", alternatives: ["18 g of grapes."]))
    }

    @Test func eachStretchSwapsAlone() {
        let t = Transcriber.join([part("A bowl of great yogurt", ["A bowl of greek yogurt"]),
                                  part(" and one pair.", ["and one pear.", " and one pair."])])
        #expect(t.text == "A bowl of great yogurt and one pair.")
        #expect(t.alternatives == ["A bowl of greek yogurt and one pair.", "A bowl of great yogurtand one pear."])
    }

    @Test func nothingHeard() {
        #expect(Transcriber.join([]) == .init(text: ""))
    }
}
