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
        var items: [Item] = []

        var kcal: Double { items.reduce(0) { $0 + (($1.values["kcal"] ?? nil) ?? 0) } }
        var said: String { [transcript, text].compactMap { $0 }.joined(separator: " ") }
        /// What was eaten, one line: the items when logged, else what was said.
        var what: String {
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
            status     TEXT NOT NULL,          -- queued | transcribing | thinking | waiting | done | nothing | error
            reply      TEXT,                   -- the model's one-line summary / assumptions
            error      TEXT,
            meal       TEXT,
            model      TEXT,                   -- the profile that handled it
            edits      TEXT,                   -- JSON list of the change requests applied, in order
            pending_edit TEXT                  -- a change request (its text) waiting its turn
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

    /// Redo with the model from scratch: the items, summary and changes go.
    func redo(_ id: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM item WHERE entry_id=?", [.int(id)])
            try db.run("UPDATE entry SET status='queued', error=NULL, reply=NULL, edits=NULL, pending_edit=NULL WHERE id=?",
                       [.int(id)])
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

    /// Adds an item by hand at the end of an entry.
    func appendItem(_ entryID: Int64, _ it: NewItem) throws {
        let next = try db.rows("SELECT COALESCE(MAX(ord), -1) + 1 AS n FROM item WHERE entry_id=?", [.int(entryID)])
            .first?["n"]?.int ?? 0
        try insertItem(entryID, ord: next, it)
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

    private func entry(_ r: SQLite.Row) throws -> Entry {
        let id = Int64(r["id"]?.int ?? 0)
        let items = try db.rows("SELECT * FROM item WHERE entry_id=? ORDER BY ord", [.int(id)]).map { i in
            Item(id: Int64(i["id"]?.int ?? 0), fdcID: i["fdc_id"]?.int ?? 0, description: i["description"]?.string ?? "",
                 said: i["said"]?.string, grams: i["grams"]?.double ?? 0, basis: i["basis"]?.string ?? "",
                 note: i["note"]?.string,
                 adjust: try i["adjust"]?.string.map { try JSONDecoder().decode(Nutrition.Adjust.self, from: Data($0.utf8)) },
                 values: Dictionary(uniqueKeysWithValues: FoodDB.nutrientKeys.map { ($0, i[$0]?.double) }))
        }
        return Entry(id: id, createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                     tz: r["tz"]?.string ?? TimeZone.current.identifier, day: r["day"]?.string ?? "",
                     text: r["text"]?.string, transcript: r["transcript"]?.string, audio: r["audio"]?.string,
                     photo: r["photo"]?.string,
                     status: Status(rawValue: r["status"]?.string ?? "") ?? .error, reply: r["reply"]?.string,
                     error: r["error"]?.string, meal: r["meal"]?.string, model: r["model"]?.string,
                     edits: try r["edits"]?.string.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
                     pendingEdit: r["pending_edit"]?.string, items: items)
    }

    /// The local date of `date` in `tz`, YYYY-MM-DD.
    static func day(_ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
