import Foundation
import Observation

/// The food log on the phone: entries (what the user said or typed) and the
/// items logged from them. A port of store.py's schema without users, logins
/// or upload ids: one user per phone, nothing uploaded.
@Observable
final class LogDB {
    enum Status: String {
        /// waiting for a model (none reachable yet) or for its turn
        case queued
        /// speech-to-text is turning the recording into words
        case transcribing
        case thinking
        /// the server asked us to wait (another model loaded, rate limited)
        case waiting
        case done
        /// the input had no food in it
        case nothing
        case error
    }

    struct Entry: Identifiable, Equatable {
        let id: Int64
        let createdAt: Date
        /// The phone's time zone when it was recorded; decides the day and the
        /// entry time the model is told.
        let tz: String
        var day: String
        var text: String?
        var transcript: String?
        /// The recognizer's other readings of the recording, whole.
        var alternatives: [String] = []
        /// Media file names (see `Media`).
        var audio: String?
        var photo: String?
        var status: Status
        var reply: String?
        var error: String?
        var meal: String?
        /// Which profile handled it, "name (model)".
        var model: String?
        /// The change requests applied, in order.
        var edits: [String] = []
        /// A change request waiting its turn.
        var pendingEdit: String?
        /// The profile to run its next turn with, and only it: a redo with a
        /// chosen model. Cleared when that turn ends.
        var useProfile: UUID?
        /// The user's name for it ("Smoothie"), set when entries are combined.
        var title: String?
        var items: [Item] = []

        var kcal: Double { items.reduce(0) { $0 + (($1.values["kcal"] ?? nil) ?? 0) } }
        var said: String { [transcript, text].compactMap { $0 }.joined(separator: " ") }
        /// What was eaten, one line: the items when logged, else what was said.
        var what: String {
            if let title { return title }
            if status == .done || pendingEdit != nil, !items.isEmpty {
                return items.map { $0.said ?? $0.description }.joined(separator: ", ")
            }
            if !said.isEmpty { return said }
            return photo != nil ? "Photo" : audio != nil ? "Voice note" : "Entry"
        }
        func total(_ k: String) -> Double { items.reduce(0) { $0 + (($1.values[k] ?? nil) ?? 0) } }
    }

    struct Item: Identifiable, Equatable {
        let id: Int64
        let fdcID: Int
        let description: String
        let said: String?
        let grams: Double
        let basis: String
        let note: String?
        let adjust: Nutrition.Adjust?
        /// For `grams`, every `FoodDB.nutrientKeys` key present.
        let values: FoodDB.Nutrients
    }

    /// What `replaceItems` stores for one item.
    struct NewItem {
        let fdcID: Int
        let description: String
        let said: String?
        let grams: Double
        let basis: String
        let note: String?
        let adjust: Nutrition.Adjust?
        let values: FoodDB.Nutrients
    }

    static let schema = """
        CREATE TABLE IF NOT EXISTS entry (
            id         INTEGER PRIMARY KEY,
            created_at REAL NOT NULL,          -- when the user recorded it, seconds since 1970 (UTC)
            tz         TEXT NOT NULL,          -- the phone's IANA zone then
            day        TEXT NOT NULL,          -- local date the food was eaten (YYYY-MM-DD)
            audio      TEXT,                   -- media file names (voice and photo entries, later)
            photo      TEXT,
            text       TEXT,                   -- typed text
            transcript TEXT,                   -- what speech-to-text heard
            alternatives TEXT,                 -- JSON list: its other readings of the recording
            status     TEXT NOT NULL,          -- queued | transcribing | thinking | waiting | done | nothing | error
            reply      TEXT,                   -- the model's one-line summary / assumptions
            error      TEXT,
            meal       TEXT,
            model      TEXT,                   -- the profile that handled it
            edits      TEXT,                   -- JSON list of the change requests applied, in order
            pending_edit TEXT,                 -- a change request (its text) waiting its turn
            use_profile TEXT,                  -- a profile id: run the next turn with this model only
            title      TEXT                    -- the user's name for it, given when entries are combined
        );
        CREATE INDEX IF NOT EXISTS entry_day ON entry(day);
        CREATE TABLE IF NOT EXISTS item (
            id          INTEGER PRIMARY KEY,
            entry_id    INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
            ord         INTEGER NOT NULL,
            fdc_id      INTEGER NOT NULL,
            description TEXT NOT NULL,         -- the food database's description of fdc_id
            said        TEXT,                  -- what the user called it
            grams       REAL NOT NULL,
            basis       TEXT NOT NULL,         -- weighed | portion | estimated
            note        TEXT,                  -- the model's assumption, if any
            adjust      TEXT,                  -- JSON Nutrition.Adjust: the user's version of the food
            \(FoodDB.nutrientKeys.map { "\($0) REAL" }.joined(separator: ", "))
        );
        CREATE INDEX IF NOT EXISTS item_entry ON item(entry_id);
        """

    private let db: SQLite
    /// Bumped on every write, so views that read the log redraw.
    private(set) var revision = 0

    init(path: String) throws {
        db = try SQLite(path: path, readOnly: false)
        try db.execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
        try db.execute(Self.schema)
        try migrate()
    }

    /// Columns added since a log was created.
    private func migrate() throws {
        if !(try db.columns("main", "entry")).contains("alternatives") {
            try db.execute("ALTER TABLE entry ADD COLUMN alternatives TEXT")
        }
        if !(try db.columns("main", "entry")).contains("use_profile") {
            try db.execute("ALTER TABLE entry ADD COLUMN use_profile TEXT")
        }
        if !(try db.columns("main", "entry")).contains("title") {
            try db.execute("ALTER TABLE entry ADD COLUMN title TEXT")
        }
    }

    static func app() throws -> LogDB {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return try LogDB(path: dir.appendingPathComponent(AppFiles.name("log", "db")).path)
    }

    // MARK: - writing

    /// A new entry, queued for the model: typed text, a voice recording and/or
    /// a photo (media file names). Its day is the local date now.
    func addEntry(text: String? = nil, audio: String? = nil, photo: String? = nil, at date: Date = Date(),
                  tz: TimeZone = .current) throws -> Int64 {
        defer { revision += 1 }
        func opt(_ s: String?) -> SQLite.Value { s.map(SQLite.Value.text) ?? .null }
        return try db.run("INSERT INTO entry(created_at, tz, day, text, audio, photo, status) VALUES (?,?,?,?,?,?,?)",
                          [.real(date.timeIntervalSince1970), .text(tz.identifier), .text(Self.day(date, tz)),
                           opt(text), opt(audio), opt(photo), .text(Status.queued.rawValue)])
    }

    /// Redo with the model from scratch: the items and summary go; the changes
    /// the user asked for stay, and the redo applies them again.
    /// Logs the entry again from what was said: with `profile` only, when given,
    /// else the first model that answers.
    func redo(_ id: Int64, profile: UUID? = nil) throws {
        try db.transaction {
            try db.run("DELETE FROM item WHERE entry_id=?", [.int(id)])
            try db.run("UPDATE entry SET status='queued', error=NULL, reply=NULL, pending_edit=NULL, use_profile=? WHERE id=?",
                       [profile.map { .text($0.uuidString) } ?? .null, .int(id)])
        }
        revision += 1
    }

    /// Queues a change request ("it was 200 grams") on a logged entry.
    func requestEdit(_ id: Int64, _ text: String) throws {
        try db.run("UPDATE entry SET pending_edit=?, status='queued', error=NULL WHERE id=?", [.text(text), .int(id)])
        revision += 1
    }

    /// Replaces one item's food, amount and numbers (an edit by hand).
    func setItem(_ itemID: Int64, _ it: NewItem) throws {
        let cols = ["fdc_id", "description", "said", "grams", "basis", "note", "adjust"] + FoodDB.nutrientKeys
        try db.run("UPDATE item SET \(cols.map { "\($0)=?" }.joined(separator: ", ")) WHERE id=?", try values(it) + [.int(itemID)])
        revision += 1
    }

    func deleteItem(_ itemID: Int64) throws {
        try db.run("DELETE FROM item WHERE id=?", [.int(itemID)])
        revision += 1
    }

    private func values(_ it: NewItem) throws -> [SQLite.Value] {
        let adjust = try it.adjust.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        return [.int(Int64(it.fdcID)), .text(it.description), it.said.map(SQLite.Value.text) ?? .null, .real(it.grams),
                .text(it.basis), it.note.map(SQLite.Value.text) ?? .null, adjust.map(SQLite.Value.text) ?? .null]
            + FoodDB.nutrientKeys.map { k in (it.values[k] ?? nil).map(SQLite.Value.real) ?? .null }
    }

    private func insertItem(_ entryID: Int64, ord: Int, _ it: NewItem) throws {
        let cols = ["entry_id", "ord", "fdc_id", "description", "said", "grams", "basis", "note", "adjust"] + FoodDB.nutrientKeys
        try db.run("INSERT INTO item(\(cols.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ",")))",
                   [.int(entryID), .int(Int64(ord))] + values(it))
    }

    /// Sets the given columns; a nil value clears one.
    func update(_ id: Int64, status: Status? = nil, _ fields: [String: String?] = [:]) throws {
        var all = fields
        if let status { all["status"] = status.rawValue }
        guard !all.isEmpty else { return }
        let keys = all.keys.sorted()
        try db.run("UPDATE entry SET \(keys.map { "\($0)=?" }.joined(separator: ", ")) WHERE id=?",
                   keys.map { all[$0]!.map(SQLite.Value.text) ?? .null } + [.int(id)])
        revision += 1
    }

    func replaceItems(_ entryID: Int64, _ items: [NewItem]) throws {
        let cols = ["entry_id", "ord", "fdc_id", "description", "said", "grams", "basis", "note", "adjust"]
            + FoodDB.nutrientKeys
        try db.transaction {
            try db.run("DELETE FROM item WHERE entry_id=?", [.int(entryID)])
            for (i, it) in items.enumerated() { try insertItem(entryID, ord: i, it) }
        }
        revision += 1
    }

    /// Entries made one: the earliest keeps its time and meal and takes every
    /// item, in time order, and the others are deleted. What was said becomes
    /// its text, joined, so a redo logs the whole thing again; recordings go,
    /// since their words are kept, and the first photo stays. Only logged
    /// entries of one day, none with a change waiting.
    func combine(_ ids: [Int64], title: String?) throws -> Int64 {
        let es = try Set(ids).map { id in
            guard let e = try entry(id) else { throw SQLite.Failure.sqlite("entry \(id) is gone") }
            return e
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard es.count >= 2 else { throw SQLite.Failure.sqlite("Pick two or more entries to combine.") }
        guard es.allSatisfy({ $0.status == .done && $0.pendingEdit == nil }) else {
            throw SQLite.Failure.sqlite("Only entries that are done logging can be combined.")
        }
        guard Set(es.map(\.day)).count == 1 else { throw SQLite.Failure.sqlite("Only entries of one day can be combined.") }
        let keep = es[0], rest = es.dropFirst()
        let photo = es.lazy.compactMap(\.photo).first
        let said = es.map(\.said).filter { !$0.isEmpty }.joined(separator: "\n")
        let models = es.compactMap(\.model).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let edits = String(decoding: try JSONEncoder().encode(es.flatMap(\.edits)), as: UTF8.self)
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        func opt(_ s: String?) -> SQLite.Value { s.map(SQLite.Value.text) ?? .null }
        try db.transaction {
            var ord = 0
            for e in es {
                for i in e.items {
                    try db.run("UPDATE item SET entry_id=?, ord=? WHERE id=?", [.int(keep.id), .int(Int64(ord)), .int(i.id)])
                    ord += 1
                }
            }
            try db.run("""
                UPDATE entry SET title=?, text=?, transcript=NULL, alternatives=NULL, audio=NULL, photo=?, reply=NULL,
                error=NULL, model=?, edits=? WHERE id=?
                """, [opt(t?.isEmpty == false ? t : nil), opt(said.isEmpty ? nil : said), opt(photo),
                      opt(models.isEmpty ? nil : models.joined(separator: ", ")), .text(edits), .int(keep.id)])
            for e in rest { try db.run("DELETE FROM entry WHERE id=?", [.int(e.id)]) }
        }
        for e in es {
            Media.remove(e.audio)
            if e.photo != photo { Media.remove(e.photo) }
        }
        revision += 1
        return keep.id
    }

    /// Deletes the entry, its items, and its recording and photo.
    func deleteEntry(_ id: Int64) throws {
        let media = try db.rows("SELECT audio, photo FROM entry WHERE id=?", [.int(id)]).first
        try db.run("DELETE FROM entry WHERE id=?", [.int(id)])
        Media.remove(media?["audio"]?.string)
        Media.remove(media?["photo"]?.string)
        revision += 1
    }

    // MARK: - reading

    func entry(_ id: Int64) throws -> Entry? {
        try db.rows("SELECT * FROM entry WHERE id=?", [.int(id)]).first.map(entry)
    }

    /// One day's entries, oldest first, with their items.
    func entries(day: String) throws -> [Entry] {
        try db.rows("SELECT * FROM entry WHERE day=? ORDER BY created_at", [.text(day)]).map(entry)
    }

    /// The day's totals over all its items; a nutrient no item has is 0.
    func totals(day: String) throws -> [String: Double] {
        let sums = FoodDB.nutrientKeys.map { "COALESCE(SUM(i.\($0)), 0) AS \($0)" }.joined(separator: ", ")
        let row = try db.rows("SELECT \(sums) FROM entry e JOIN item i ON i.entry_id = e.id WHERE e.day=?",
                              [.text(day)]).first ?? [:]
        return Dictionary(uniqueKeysWithValues: FoodDB.nutrientKeys.map { ($0, row[$0]?.double ?? 0) })
    }

    /// Entries the model still has to process, oldest first: queued, or cut off
    /// mid-run (the app was closed while it worked).
    func unfinished() throws -> [Int64] {
        try db.rows("SELECT id FROM entry WHERE status IN ('queued','transcribing','thinking','waiting') ORDER BY id")
            .compactMap { $0["id"]?.int.map(Int64.init) }
    }

    struct DayTotal: Identifiable, Equatable {
        let day: String
        let entries: Int
        let kcal, proteinG, fatG, carbG: Double
        var id: String { day }
    }

    /// Per-day totals, newest first (days with any entry).
    func days(limit: Int) throws -> [DayTotal] {
        try db.rows("""
            SELECT e.day, COUNT(DISTINCT e.id) AS entries, COALESCE(SUM(i.kcal), 0) AS kcal,
            COALESCE(SUM(i.protein_g), 0) AS p, COALESCE(SUM(i.fat_g), 0) AS f, COALESCE(SUM(i.carb_g), 0) AS c
            FROM entry e LEFT JOIN item i ON i.entry_id = e.id GROUP BY e.day ORDER BY e.day DESC LIMIT ?
            """, [.int(Int64(limit))]).map {
            DayTotal(day: $0["day"]?.string ?? "", entries: $0["entries"]?.int ?? 0, kcal: $0["kcal"]?.double ?? 0,
                     proteinG: $0["p"]?.double ?? 0, fatG: $0["f"]?.double ?? 0, carbG: $0["c"]?.double ?? 0)
        }
    }

    private func item(_ i: SQLite.Row) throws -> Item {
        Item(id: Int64(i["id"]?.int ?? 0), fdcID: i["fdc_id"]?.int ?? 0, description: i["description"]?.string ?? "",
             said: i["said"]?.string, grams: i["grams"]?.double ?? 0, basis: i["basis"]?.string ?? "",
             note: i["note"]?.string,
             adjust: try i["adjust"]?.string.map { try JSONDecoder().decode(Nutrition.Adjust.self, from: Data($0.utf8)) },
             values: Dictionary(uniqueKeysWithValues: FoodDB.nutrientKeys.map { ($0, i[$0]?.double) }))
    }

    /// Items of logged entries recorded in [since, before), other than this
    /// entry, latest first.
    func recentItems(excluding id: Int64, since: Date, before: Date) throws -> [Item] {
        try db.rows("""
            SELECT i.* FROM item i JOIN entry e ON e.id = i.entry_id
            WHERE e.id != ? AND e.status = 'done' AND e.created_at >= ? AND e.created_at < ?
            ORDER BY e.created_at DESC, e.id DESC, i.ord
            """, [.int(id), .real(since.timeIntervalSince1970), .real(before.timeIntervalSince1970)]).map(item)
    }

    private func entry(_ r: SQLite.Row) throws -> Entry {
        let id = Int64(r["id"]?.int ?? 0)
        let items = try db.rows("SELECT * FROM item WHERE entry_id=? ORDER BY ord", [.int(id)]).map(item)
        return Entry(id: id, createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                     tz: r["tz"]?.string ?? TimeZone.current.identifier, day: r["day"]?.string ?? "",
                     text: r["text"]?.string, transcript: r["transcript"]?.string,
                     alternatives: try r["alternatives"]?.string.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
                     audio: r["audio"]?.string,
                     photo: r["photo"]?.string,
                     status: Status(rawValue: r["status"]?.string ?? "") ?? .error, reply: r["reply"]?.string,
                     error: r["error"]?.string, meal: r["meal"]?.string, model: r["model"]?.string,
                     edits: try r["edits"]?.string.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
                     pendingEdit: r["pending_edit"]?.string, useProfile: r["use_profile"]?.string.flatMap(UUID.init),
                     title: r["title"]?.string, items: items)
    }

    // MARK: - export and load

    /// What a loaded export's log.db must have: the columns this schema can't do without.
    static let required = ["entry": ["id", "created_at", "tz", "day", "status"],
                           "item": ["id", "entry_id", "ord", "fdc_id", "description", "grams", "basis"]]

    /// A standalone copy of the log for an export: without which model handled
    /// or will handle each entry, so the file holds nothing about the model setup. Secure
    /// delete overwrites the old values rather than leaving them in free pages.
    func copy(to url: URL) throws {
        try db.copy("main", to: url.path)
        let out = try SQLite(path: url.path, readOnly: false)
        try out.execute("PRAGMA journal_mode = DELETE; PRAGMA secure_delete = ON; UPDATE entry SET model = NULL, use_profile = NULL; VACUUM;")
    }

    /// Replaces the whole log with another log file's.
    func replaceAll(from url: URL) throws {
        defer { revision += 1 }
        try db.replaceRows("main", tables: ["entry", "item"], from: url.path)
    }

    /// Every media file name the log refers to.
    func mediaNames() throws -> Set<String> {
        Set(try db.rows("SELECT audio AS n FROM entry WHERE audio IS NOT NULL UNION SELECT photo FROM entry WHERE photo IS NOT NULL")
            .compactMap { $0["n"]?.string })
    }

    struct Summary: Equatable {
        let entries: Int
        let first: String?
        let last: String?
    }

    func summary() throws -> Summary { try Self.summary(db) }

    /// Checks a loaded export's log and says what's in it.
    static func checkLog(_ url: URL) throws -> Summary {
        let db = try SQLite.checked(url.path, required: required, what: "The log")
        guard try db.rows("SELECT 1 FROM item WHERE entry_id NOT IN (SELECT id FROM entry) LIMIT 1").isEmpty else {
            throw SQLite.Failure.sqlite("The log in this file has foods that belong to no entry.")
        }
        return try summary(db)
    }

    private static func summary(_ db: SQLite) throws -> Summary {
        let r = try db.rows("SELECT COUNT(*) AS n, MIN(day) AS a, MAX(day) AS b FROM entry").first ?? [:]
        return Summary(entries: r["n"]?.int ?? 0, first: r["a"]?.string, last: r["b"]?.string)
    }

    /// The local date of `date` in `tz`, YYYY-MM-DD.
    static func day(_ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
