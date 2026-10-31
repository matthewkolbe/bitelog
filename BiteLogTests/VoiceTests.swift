import Foundation
import Testing
@testable import BiteLog

/// Apple's on-device speech to text on the web app's own recordings, next to
/// what Parakeet heard for them. Runs on an iPhone, not the Simulator (it has
/// no working speech model). Only when asked:
///   TEST_RUNNER_BITELOG_STT=<folder with media/*.wav> TEST_RUNNER_BITELOG_STT_OUT=<file.tsv> xcodebuild … test
@MainActor
struct VoiceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_STT"] != nil), .timeLimit(.minutes(20)))
    func compareWithParakeet() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["BITELOG_STT"]!)
        let db = try SQLite(path: dir.appendingPathComponent("calories.db").path, readOnly: true)
        let rows = try db.rows("SELECT audio, transcript FROM entry WHERE audio IS NOT NULL AND transcript IS NOT NULL ORDER BY id")
        var out = "file\tparakeet\tapple\n"
        var heard = 0
        for r in rows {
            let name = r["audio"]!.string!, parakeet = r["transcript"]!.string!
            let file = dir.appendingPathComponent("media").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let apple = try await Transcriber.transcribe(file)
            if !apple.isEmpty { heard += 1 }
            out += "\(name)\t\(parakeet)\t\(apple)\n"
        }
        if let path = env["BITELOG_STT_OUT"] { try out.write(toFile: path, atomically: true, encoding: .utf8) }
        #expect(heard > 0)
    }
}
