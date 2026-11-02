import Foundation
import Testing
@testable import BiteLog

/// Export and load: a file from one phone makes another phone's log, foods,
/// media and targets the same, and a file that isn't a Bite Log export, or is
/// damaged, changes nothing.
@MainActor
struct BackupTests {
    /// One phone's data, in temporary files.
    struct Phone {
        let foods: FoodDB
        let log: LogDB
        let media: URL
        let defaults: UserDefaults

        init() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID())")
            media = tmp.appendingPathComponent("media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            foods = try FoodDB(usda: try #require(Bundle.main.url(forResource: "fdc", withExtension: "db")),
                               custom: tmp.appendingPathComponent("custom_foods.db"))
            log = try LogDB(path: tmp.appendingPathComponent("log.db").path)
            defaults = try #require(UserDefaults(suiteName: "backup-\(UUID())"))
        }

        func mediaFiles() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: media.path).map {
                ($0, try Data(contentsOf: media.appendingPathComponent($0)))
            })
        }

        func everything() throws -> [LogDB.Entry] {
            try log.days(limit: 1000).flatMap { try log.entries(day: $0.day) }
        }
    }

    static func item(_ fdcID: Int, _ grams: Double, kcal: Double) -> LogDB.NewItem {
        .init(fdcID: fdcID, description: "food \(fdcID)", said: "said \(fdcID)", grams: grams, basis: "weighed",
              note: nil, adjust: .init(why: "4% skyr", per100g: ["fat_g": 4], factors: ["fat_g": 2.94]),
              values: ["kcal": kcal, "protein_g": 10])
    }

    /// A phone with two days of entries, a photo, a custom food and targets.
    static func filled() throws -> Phone {
        let p = try Phone()
        let photo = "\(UUID().uuidString.lowercased()).jpg"
        try Data("jpeg bytes".utf8).write(to: p.media.appendingPathComponent(photo))
        let jerky = try p.foods.addCustomFood(name: "Sugar free beef jerky", servingLabel: "1 oz (28g)", servingG: 28,
                                              perServing: ["kcal": 70, "protein_g": 12, "fat_g": 1, "carb_g": 3])
        let a = try p.log.addEntry(text: "skyr", at: Date(timeIntervalSince1970: 1_790_000_000), tz: .gmt)
        try p.log.replaceItems(a, [item(2259794, 105, kcal: 103)])
        try p.log.update(a, status: .done, ["reply": "logged", "edits": "[\"it was 105 g\"]",
                                             "model": "Home Qwen (qwen38-secret-name)"])
        let b = try p.log.addEntry(photo: photo, at: Date(timeIntervalSince1970: 1_790_090_000), tz: .gmt)
        try p.log.replaceItems(b, [item(jerky.fdcID, 28, kcal: 70), item(173040, 50, kcal: 35)])
        try p.log.update(b, status: .done)
        p.defaults.set(1900, forKey: Goals.kcalKey)
        p.defaults.set(140, forKey: Goals.proteinKey)
        return p
    }

    @Test func roundTrip() async throws {
        let source = try Self.filled()
        let file = try await Backup.export(log: source.log, foods: source.foods, media: source.media,
                                           defaults: source.defaults)
        // nothing about the model setup is in the file, not even in the log's free space
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("qwen38-secret-name".utf8)) == nil)
        // TEST_RUNNER_BITELOG_EXPORT=<dir> keeps a copy, to check with other zip tools
        if let keep = ProcessInfo.processInfo.environment["BITELOG_EXPORT"] {
            let dest = URL(fileURLWithPath: keep).appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
        }

        // the other phone has its own entry, food, an unused file and targets, all replaced
        let dest = try Phone()
        let old = try dest.log.addEntry(text: "old")
        try dest.log.replaceItems(old, [Self.item(173040, 10, kcal: 7)])
        _ = try dest.foods.addCustomFood(name: "Old food", servingG: 10,
                                         perServing: ["kcal": 40, "protein_g": 1, "fat_g": 4, "carb_g": 1])
        try Data("stray".utf8).write(to: dest.media.appendingPathComponent("stray.wav"))
        dest.defaults.set(2500, forKey: Goals.kcalKey)

        let opened = try await Backup.open(file)
        #expect(opened.log == .init(entries: 2, first: "2026-09-21", last: "2026-09-22"))
        #expect(opened.foods == 1)
        #expect(opened.manifest.format == Backup.format)
        #expect(opened.manifest.kcalGoal == 1900)
        try Backup.load(opened, log: dest.log, foods: dest.foods, media: dest.media, defaults: dest.defaults)

        // the same log, less which model handled each entry
        let stripped = try source.everything().map { e in var e = e; e.model = nil; return e }
        #expect(try dest.everything() == stripped)
        #expect(try source.everything().contains { $0.model != nil })
        #expect(try dest.foods.customFoods() == source.foods.customFoods())
        #expect(try dest.mediaFiles() == source.mediaFiles())
        #expect(dest.defaults.double(forKey: Goals.kcalKey) == 1900)
        #expect(dest.defaults.double(forKey: Goals.proteinKey) == 140)
        #expect(!FileManager.default.fileExists(atPath: opened.dir.path))
    }

    /// Writes a zip of these (name, contents) for the tests below.
    static func zip(_ files: [(String, Data)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = try files.enumerated().map { i, f in
            let u = dir.appendingPathComponent("\(i)")
            try f.1.write(to: u)
            return (name: f.0, url: u)
        }
        let out = dir.appendingPathComponent("test.zip")
        try Zip.write(list, to: out)
        return out
    }

    /// An export's files, unpacked, for building broken ones.
    static func exportParts() async throws -> [(String, Data)] {
        let p = try Self.filled()
        let file = try await Backup.export(log: p.log, foods: p.foods, media: p.media, defaults: p.defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parts-\(UUID())")
        return try Zip.read(file, into: dir, accept: { _ in true }).map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) }
    }

    @Test func refusesWhatIsntAnExport() async throws {
        let parts = try await Self.exportParts()
        func failure(_ files: [(String, Data)]) async throws -> String {
            let file = try Self.zip(files)
            do {
                _ = try await Backup.open(file)
                return "opened"
            } catch {
                return String(describing: error)
            }
        }
        #expect(try await failure(parts.filter { $0.0 != "log.db" }) == "This isn't a Bite Log export: it has no log.db.")
        #expect(try await failure(parts + [("../escape.txt", Data("x".utf8))])
                == "This zip has a file Bite Log doesn't expect: ../escape.txt")
        #expect(try await failure(parts + [("media/../../x", Data("x".utf8))])
                == "This zip has a file Bite Log doesn't expect: media/../../x")
        let newer = parts.map { $0.0 == "bitelog.json"
            ? ($0.0, Data(String(decoding: $0.1, as: UTF8.self).replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 2").utf8))
            : $0 }
        #expect(try await failure(newer) == "This file is from a newer Bite Log. Update the app to load it.")
        let notDB = parts.map { $0.0 == "log.db" ? ($0.0, Data("not a database".utf8)) : $0 }
        #expect(try await failure(notDB).contains("not a database"))
        // a Mac's re-zip adds these; they're skipped
        #expect(try await failure(parts + [("__MACOSX/._log.db", Data()), (".DS_Store", Data())]) == "opened")
    }

    @Test func damagedFileIsRefused() throws {
        let file = try Self.zip([("log.db", Data(repeating: 7, count: 100))])
        var bytes = try Data(contentsOf: file)
        bytes[40] ^= 0xFF  // inside the file's data: its checksum no longer matches
        try bytes.write(to: file)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
        #expect(throws: Zip.Failure.self) { try Zip.read(file, into: dir, accept: { _ in true }) }
    }

    /// Made by Python's zipfile: a folder entry, a deflated file and a stored one.
    @Test func readsDeflatedZips() throws {
        let b64 = "UEsDBBQAAAAAAAAAIQAAAAAAAAAAAAAAAAAEAAAAZGlyL1BLAwQUAAAACABGel9dGcaqUA8AAADoAwAADAAAAGRlZmxhdGVkLnR4dCvOrixSKB4lRolRYjgTAFBLAwQUAAAAAABGel9dz2IgGQUAAAAFAAAACgAAAHN0b3JlZC50eHRwbGFpblBLAQIUAxQAAAAAAAAAIQAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAACAAQAAAABkaXIvUEsBAhQDFAAAAAgARnpfXRnGqlAPAAAA6AMAAAwAAAAAAAAAAAAAAIABIgAAAGRlZmxhdGVkLnR4dFBLAQIUAxQAAAAAAEZ6X13PYiAZBQAAAAUAAAAKAAAAAAAAAAAAAACAAVsAAABzdG9yZWQudHh0UEsFBgAAAAADAAMApAAAAIgAAAAAAA=="
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("py-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("py.zip")
        try #require(Data(base64Encoded: b64)).write(to: file)
        let out = tmp.appendingPathComponent("out")
        #expect(try Zip.read(file, into: out, accept: { _ in true }) == ["deflated.txt", "stored.txt"])
        #expect(try Data(contentsOf: out.appendingPathComponent("deflated.txt")) == Data(String(repeating: "skyr ", count: 200).utf8))
        #expect(try Data(contentsOf: out.appendingPathComponent("stored.txt")) == Data("plain".utf8))
    }
}
