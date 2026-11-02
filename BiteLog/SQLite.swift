import Foundation
import SQLite3

/// A thin wrapper over the system SQLite (which has FTS5 with the porter
/// tokenizer, as `fdc.db`'s search index needs).
final class SQLite {
    enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String { if case .sqlite(let m) = self { m } else { "" } }
    }

    /// A column value as SQLite stores it.
    enum Value: Equatable {
        case null, int(Int64), real(Double), text(String)

        var double: Double? {
            switch self {
            case .int(let i): Double(i)
            case .real(let d): d
            default: nil
            }
        }
        var int: Int? { if case .int(let i) = self { Int(i) } else { nil } }
        var string: String? { if case .text(let s) = self { s } else { nil } }
    }

    typealias Row = [String: Value]

    private let db: OpaquePointer

    /// `readOnly` opens the file through a `mode=ro&immutable=1` URI: the bundled
    /// database never changes and lives in a read-only directory, so SQLite must
    /// not try to lock it. Only the file is read-only, not the connection — a
    /// read-only connection couldn't ATTACH (or create) a writable database.
    init(path: String, readOnly: Bool) throws {
        var h: OpaquePointer?
        let uri = readOnly ? "file:\(path)?mode=ro&immutable=1" : path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | (readOnly ? SQLITE_OPEN_URI : 0)
        let rc = sqlite3_open_v2(uri, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(h)
            throw Failure.sqlite("open \(path): \(msg)")
        }
        db = h
    }

    isolated deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
    }

    /// One write statement with arguments; returns the last inserted rowid.
    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int64 {
        _ = try rows(sql, args)
        return sqlite3_last_insert_rowid(db)
    }

    /// `body` inside a transaction: all of it or none.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let out = try body()
            try execute("COMMIT")
            return out
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rows(_ sql: String, _ args: [Value] = []) throws -> [Row] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw error(sql) }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(st, n)
            case .int(let v): sqlite3_bind_int64(st, n, v)
            case .real(let v): sqlite3_bind_double(st, n, v)
            case .text(let v): sqlite3_bind_text(st, n, v, -1, SQLITE_TRANSIENT)
            }
        }
        var out: [Row] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(sql) }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(st, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(st, c)))
                default: row[name] = .null
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: - whole-database copies (export and load)

    /// A standalone copy of one attached database ("main", "custom") at `path`.
    func copy(_ schema: String, to path: String) throws {
        try run("VACUUM \(schema) INTO ?", [.text(path)])
    }

    func columns(_ schema: String, _ table: String) throws -> [String] {
        try rows("PRAGMA \(schema).table_info(\(table))").compactMap { $0["name"]?.string }
    }

    /// Replaces the rows of `schema`'s tables with those of the same tables in
    /// the database file at `path`, copying the columns both sides have: all
    /// or nothing. Tables are emptied last to first and filled first to last,
    /// so a table others refer to comes first.
    func replaceRows(_ schema: String, tables: [String], from path: String) throws {
        try run("ATTACH DATABASE ? AS imported", [.text(path)])
        defer { try? execute("DETACH DATABASE imported") }
        try transaction {
            for t in tables.reversed() { try execute("DELETE FROM \(schema).\(t)") }
            for t in tables {
                let theirs = Set(try columns("imported", t))
                let cols = try columns(schema, t).filter(theirs.contains).joined(separator: ", ")
                try execute("INSERT INTO \(schema).\(t)(\(cols)) SELECT \(cols) FROM imported.\(t)")
            }
        }
    }

    /// Opens a database file that came from outside the app (a loaded export)
    /// and checks it before anything is copied from it: intact, and with each
    /// table in `required` holding at least those columns.
    static func checked(_ path: String, required: [String: [String]], what: String) throws -> SQLite {
        let db = try SQLite(path: path, readOnly: false)
        guard try db.rows("PRAGMA quick_check").first?.values.first == .text("ok") else {
            throw Failure.sqlite("\(what) in this file is damaged.")
        }
        for (table, cols) in required {
            guard try !db.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]).isEmpty else {
                throw Failure.sqlite("\(what) in this file has no \(table) table.")
            }
            let missing = Set(cols).subtracting(try db.columns("main", table))
            guard missing.isEmpty else {
                throw Failure.sqlite("\(what) in this file is missing \(table) columns: \(missing.sorted().joined(separator: ", ")).")
            }
        }
        return db
    }

    private func error(_ sql: String) -> Failure {
        .sqlite("\(String(cString: sqlite3_errmsg(db))) — in: \(sql)")
    }
}

// SQLite's "copy this string now" destructor, which Swift can't import as a macro.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
