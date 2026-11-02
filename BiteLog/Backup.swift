import Foundation

/// Your data in one file and back again: a zip of the log, your foods, the
/// entries' photos and recordings, and the daily targets. Models aren't in it:
/// their keys never leave this phone's Keychain, so a new phone sets its own up.
/// Loading a file replaces everything here.
///
///     bitelog.json      format, app version, when, targets
///     log.db            the log (LogDB's schema)
///     custom_foods.db   your foods (FoodDB's custom schema)
///     media/<name>      photos and recordings the log refers to
enum Backup {
    /// Bumped when a newer app writes files an older one can't load.
    static let format = 1

    struct Manifest: Codable, Equatable {
        let format: Int
        let app: String
        let exportedAt: Date
        let kcalGoal: Double
        let proteinGoal: Double

        enum CodingKeys: String, CodingKey {
            case format, app, exportedAt = "exported_at", kcalGoal = "kcal_goal", proteinGoal = "protein_goal"
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// A file that was unpacked and checked, waiting for the user's yes.
    struct Opened: Identifiable {
        var id: URL { dir }
        let dir: URL
        let manifest: Manifest
        let log: LogDB.Summary
        let foods: Int
    }

    static func filename(_ date: Date = Date()) -> String { "Bite Log \(LogDB.day(date, .current)).zip" }

    // MARK: - export

    /// Writes an export into a new temporary folder; returns the zip.
    static func export(log: LogDB, foods: FoodDB, media: URL, defaults: UserDefaults = .standard,
                       at date: Date = Date()) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try log.copy(to: work.appendingPathComponent("log.db"))
        try foods.copyCustom(to: work.appendingPathComponent("custom_foods.db"))
        let manifest = Manifest(format: format, app: appVersion, exportedAt: date,
                                kcalGoal: defaults.double(forKey: Goals.kcalKey),
                                proteinGoal: defaults.double(forKey: Goals.proteinKey))
        try encoder.encode(manifest).write(to: work.appendingPathComponent("bitelog.json"))

        var files = ["bitelog.json", "log.db", "custom_foods.db"].map { (name: $0, url: work.appendingPathComponent($0)) }
        for name in try log.mediaNames().sorted() where isMediaName(name) {
            let u = media.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { files.append((name: "media/\(name)", url: u)) }
        }
        let out = work.appendingPathComponent(filename(date))
        let list = files
        try await Task.detached { try Zip.write(list, to: out, at: date) }.value
        return out
    }

    // MARK: - load

    /// Unpacks and checks a file the user picked. Nothing here changes yet.
    static func open(_ file: URL) async throws -> Opened {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        do {
            let names = try await Task.detached {
                try Zip.read(file, into: dir, accept: allowed, skip: junk)
            }.value
            for need in ["bitelog.json", "log.db", "custom_foods.db"] where !names.contains(need) {
                throw Failure("This isn't a Bite Log export: it has no \(need).")
            }
            let manifest: Manifest
            do {
                manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("bitelog.json")))
            } catch {
                throw Failure("This isn't a Bite Log export: its bitelog.json can't be read.")
            }
            guard manifest.format <= format else {
                throw Failure("This file is from a newer Bite Log. Update the app to load it.")
            }
            return Opened(dir: dir, manifest: manifest,
                          log: try LogDB.checkLog(dir.appendingPathComponent("log.db")),
                          foods: try FoodDB.checkCustom(dir.appendingPathComponent("custom_foods.db")))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Replaces the log, foods, media and targets with the opened file's. The
    /// caller makes sure no entry is being processed.
    static func load(_ o: Opened, log: LogDB, foods: FoodDB, media: URL, defaults: UserDefaults = .standard) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: o.dir) }
        // the foods as they were, to put back if the log can't be replaced after them
        let undo = fm.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString).db")
        try foods.copyCustom(to: undo)
        defer { try? fm.removeItem(at: undo) }

        // media first, only names not already here, so a failure can take them back out
        var added: [URL] = []
        let theirs = o.dir.appendingPathComponent("media")
        do {
            for name in (try? fm.contentsOfDirectory(atPath: theirs.path)) ?? [] {
                let dest = media.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: theirs.appendingPathComponent(name), to: dest)
                    added.append(dest)
                }
            }
            try foods.replaceCustom(from: o.dir.appendingPathComponent("custom_foods.db"))
            do {
                try log.replaceAll(from: o.dir.appendingPathComponent("log.db"))
            } catch {
                try foods.replaceCustom(from: undo)
                throw error
            }
        } catch {
            for u in added { try? fm.removeItem(at: u) }
            throw error
        }

        // the old log's photos and recordings the new one doesn't use
        let keep = try log.mediaNames()
        for name in try fm.contentsOfDirectory(atPath: media.path) where !keep.contains(name) {
            try fm.removeItem(at: media.appendingPathComponent(name))
        }
        defaults.set(o.manifest.kcalGoal, forKey: Goals.kcalKey)
        defaults.set(o.manifest.proteinGoal, forKey: Goals.proteinKey)
    }

    /// Drops an opened file the user said no to.
    static func discard(_ o: Opened) { try? FileManager.default.removeItem(at: o.dir) }

    // MARK: - names

    /// The names an export may hold; nothing else is unpacked.
    nonisolated static func allowed(_ name: String) -> Bool {
        if ["bitelog.json", "log.db", "custom_foods.db"].contains(name) { return true }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "media" && isMediaName(String(parts[1]))
    }

    /// What a computer adds when it re-zips the files: skipped, not an error.
    nonisolated static func junk(_ name: String) -> Bool {
        name.hasPrefix("__MACOSX/") || name.split(separator: "/").last == ".DS_Store"
    }

    /// A media file name as `Media` makes them: letters, digits, - _ and a dot.
    nonisolated static func isMediaName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("..")
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private static var appVersion: String {
        let i = Bundle.main.infoDictionary ?? [:]
        return "Bite Log \(i["CFBundleShortVersionString"] as? String ?? "?") (\(i["CFBundleVersion"] as? String ?? "?"))"
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
