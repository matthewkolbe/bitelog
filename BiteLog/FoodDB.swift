import Foundation

/// The food database: USDA FoodData Central (bundled `fdc.db`, read-only) plus
/// the user's custom foods (package labels and recipes) in a writable database
/// attached as `custom`. A port of the Bite Log web app's nutrition server — search ranking
/// and lookups must give the same answers as that server (BiteLogTests checks).
///
/// Custom foods carry negative ids (never colliding with an fdc_id) and source
/// "custom"; removing one only hides it, so log items that use it still recompute.
final class FoodDB {
    struct Hit: Identifiable, Equatable {
        let fdcID: Int
        let description: String
        let source: String
        let category: String?
        let kcal, proteinG, fatG, carbG: Double
        /// Set on partial matches: the query words this food lacks.
        var missing: [String]? = nil
        var id: Int { fdcID }
    }

    struct Portion: Equatable {
        let label: String
        let grams: Double
    }

    struct Food: Equatable {
        let fdcID: Int
        let description: String
        let source: String
        let category: String?
        let per100g: [String: Double?]
        let portions: [Portion]
    }

    /// The nutrients reported for a food or an amount of it, keyed by
    /// `nutrientKeys`. Every key is present; nil means USDA has no value.
    typealias Nutrients = [String: Double?]

    /// An amount of a food: grams, a portion label from `food()` times a
    /// quantity, or an amount in a unit as said (see Units.swift).
    struct Amount: Equatable {
        let fdcID: Int
        var grams: Double? = nil
        /// With a volume unit: which form's volume to use.
        var portion: String? = nil
        var quantity: Double = 1
        var amount: Double? = nil
        var unit: String? = nil
    }

    /// An amount's numbers: `values` are per `grams`, not per 100 g.
    struct Scaled: Equatable {
        let fdcID: Int
        let description: String
        let grams: Double
        var values: Nutrients
    }

    struct Meal: Equatable {
        let items: [Scaled]
        /// Summed over the items that have each value; a nutrient no item has is absent.
        let totals: [String: Double]
    }

    struct Lookup: Equatable {
        struct Alternative: Equatable {
            let fdcID: Int
            let description: String
            let source: String
            /// For the same grams as the match.
            let kcal: Double
        }
        let match: Scaled
        let source: String
        let alternatives: [Alternative]
    }

    struct Nutrient: Equatable {
        let name: String
        let amount: Double
        let unit: String
    }

    /// Messages are the nutrition server's, word for word: the model reads them
    /// and fixes its call.
    enum Failure: Error, CustomStringConvertible {
        case notFound(String), noWords, invalid(String)
        var description: String {
            switch self {
            case .notFound(let m), .invalid(let m): m
            case .noWords: "query has no words"
            }
        }
    }

    /// Food-table column -> output key, for every food.
    static let macroCols = ["kcal_100g": "kcal", "protein_g": "protein_g", "fat_g": "fat_g",
                            "carb_g": "carb_g", "fiber_g": "fiber_g", "sugar_g": "sugar_g"]
    /// USDA nutrient id -> output key.
    static let extra = [1258: "sat_fat_g", 1093: "sodium_mg", 1253: "cholesterol_mg"]
    static let nutrientKeys = ["kcal", "protein_g", "fat_g", "carb_g", "fiber_g", "sugar_g",
                               "sat_fat_g", "sodium_mg", "cholesterol_mg"]
    static let category = ["label": "Custom (from package label)",
                           "recipe": "Recipe (household, from its ingredients)"]

    static let customSchema = """
        CREATE TABLE IF NOT EXISTS custom.food (
            fdc_id       INTEGER PRIMARY KEY,   -- negative: never collides with USDA ids
            description  TEXT NOT NULL,
            aliases      TEXT NOT NULL DEFAULT '',  -- other names it is called by, for search
            serving_label TEXT,                 -- the label's serving as printed, e.g. '2 oz (56g)'
            serving_g    REAL NOT NULL,
            \(nutrientKeys.map { "\($0) REAL" }.joined(separator: ", ")),  -- per 100 g
            hidden       INTEGER NOT NULL DEFAULT 0,
            created_at   TEXT NOT NULL DEFAULT (datetime('now')),
            kind         TEXT NOT NULL DEFAULT 'label',  -- label | recipe
            recipe       TEXT                   -- recipe: JSON {text, cooked_g, ingredients}
        );
        """

    let db: SQLite

    init(usda: URL, custom: URL) throws {
        db = try SQLite(path: usda.path, readOnly: true)
        try db.execute("ATTACH DATABASE '\(custom.path.replacingOccurrences(of: "'", with: "''"))' AS custom")
        try db.execute(Self.customSchema)
    }

    /// The app's database: the bundled USDA file and custom foods in Application Support.
    static func app() throws -> FoodDB {
        guard let usda = Bundle.main.url(forResource: "fdc", withExtension: "db") else {
            throw Failure.notFound("fdc.db is missing from the app bundle")
        }
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return try FoodDB(usda: usda, custom: dir.appendingPathComponent("custom_foods.db"))
    }

    // MARK: - one food

    func food(_ fdcID: Int) throws -> Food {
        if fdcID < 0 {
            guard let f = try db.rows("SELECT * FROM custom.food WHERE fdc_id=?", [.int(Int64(fdcID))]).first else {
                throw Failure.notFound("no custom food with fdc_id \(fdcID)")
            }
            return Food(fdcID: fdcID, description: f["description"]?.string ?? "", source: "custom",
                        category: Self.category[f["kind"]?.string ?? "label"],
                        per100g: Dictionary(uniqueKeysWithValues: Self.nutrientKeys.map { ($0, f[$0]?.double.map(round2)) }),
                        portions: [Portion(label: "1 serving", grams: f["serving_g"]?.double ?? 0)])
        }
        guard let f = try db.rows("SELECT * FROM food WHERE fdc_id=?", [.int(Int64(fdcID))]).first else {
            throw Failure.notFound("no food with fdc_id \(fdcID)")
        }
        let desc = f["description"]?.string ?? ""
        guard f["kcal_100g"]?.double != nil else {
            throw Failure.notFound("fdc_id \(fdcID) (\(desc)) has no energy value in USDA's data; "
                                   + "search for another entry of the same food")
        }
        // updateValue, not subscript: assigning nil through a subscript would
        // drop the key, and a missing value must stay as a present nil
        var per: [String: Double?] = [:]
        for (col, key) in Self.macroCols { per.updateValue(f[col]?.double.map(round2), forKey: key) }
        let have = try db.rows(
            "SELECT nutrient_id, amount FROM food_nutrient WHERE fdc_id=? AND nutrient_id IN (1258, 1093, 1253)",
            [.int(Int64(fdcID))])
        let amounts = Dictionary(uniqueKeysWithValues: have.compactMap { r in
            r["nutrient_id"]?.int.map { ($0, r["amount"]?.double) } })
        for (nid, key) in Self.extra { per.updateValue((amounts[nid] ?? nil).map(round2), forKey: key) }
        let portions = try db.rows("SELECT label, gram_weight FROM portion WHERE fdc_id=? ORDER BY rowid",
                                   [.int(Int64(fdcID))])
            .map { Portion(label: $0["label"]?.string ?? "", grams: $0["gram_weight"]?.double ?? 0) }
        return Food(fdcID: fdcID, description: desc, source: f["source"]?.string ?? "",
                    category: f["category"]?.string, per100g: per, portions: portions)
    }

    /// Every nutrient USDA reports for a food (vitamins, minerals, fatty acids,
    /// amino acids), per 100 g, in USDA's nutrient order. Custom foods have none.
    func allNutrients(_ fdcID: Int) throws -> [Nutrient] {
        guard fdcID > 0 else { return [] }
        return try db.rows("""
            SELECT n.name, fn.amount, n.unit FROM food_nutrient fn JOIN nutrient n ON n.id = fn.nutrient_id
            WHERE fn.fdc_id=? AND fn.amount > 0 ORDER BY n.id
            """, [.int(Int64(fdcID))])
            .map { Nutrient(name: $0["name"]?.string ?? "", amount: $0["amount"]?.double ?? 0,
                            unit: $0["unit"]?.string ?? "") }
    }

    // MARK: - amounts

    /// Calories and macros for amounts eaten, each item scaled, plus the totals.
    func nutrition(_ items: [Amount]) throws -> Meal {
        guard !items.isEmpty else { throw Failure.invalid("items is empty") }
        // every item's shape is checked before any is looked up, as the server's schema does
        for (i, it) in items.enumerated() {
            if let m = Self.amountError(grams: it.grams, portion: it.portion, amount: it.amount, unit: it.unit) {
                throw Failure.invalid("item \(i): \(m)")
            }
            if let g = it.grams, g <= 0 { throw Failure.invalid("item \(i): grams must be more than 0") }
            if let a = it.amount, a <= 0 { throw Failure.invalid("item \(i): amount must be more than 0") }
            if it.quantity <= 0 { throw Failure.invalid("item \(i): quantity must be more than 0") }
        }
        var out: [Scaled] = []
        var totals: [String: Double] = [:]
        for it in items {
            let food = try food(it.fdcID)
            var grams = it.grams ?? 0
            if let unit = it.unit, let amount = it.amount {
                grams = try Self.grams(food, amount: amount, unit: unit, portion: it.portion, grams: it.grams)
            } else if let label = it.portion {
                let want = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let p = food.portions.first(where: { $0.label.lowercased() == want }) else {
                    let labels = food.portions.isEmpty ? "none — use grams"
                        : "[" + food.portions.map { pyRepr($0.label) }.joined(separator: ", ") + "]"
                    throw Failure.invalid("fdc_id \(it.fdcID) (\(food.description)) has no portion "
                                          + "\(pyRepr(label)); available: \(labels)")
                }
                grams = p.grams * it.quantity
            }
            let values = Self.scaled(food, grams)
            for k in Self.nutrientKeys {
                if let v = values[k] ?? nil { totals[k] = round2((totals[k] ?? 0) + v) }
            }
            out.append(Scaled(fdcID: it.fdcID, description: food.description, grams: pyRound(grams, 1),
                              values: values))
        }
        return Meal(items: out, totals: totals)
    }

    /// One-call conversion of an amount of a named food: the best match scaled
    /// to `grams`, and the next candidates with their kcal for the same grams.
    func lookup(_ name: String, grams: Double, alternatives: Int = 8) throws -> Lookup {
        guard grams > 0 else { throw Failure.invalid("grams must be more than 0") }
        let found = try search(name, limit: alternatives + 1)
        guard let first = found.first else {
            throw Failure.notFound("no food matches \(pyRepr(name)); try fewer or different words")
        }
        let best = try food(first.fdcID)
        return Lookup(
            match: Scaled(fdcID: best.fdcID, description: best.description, grams: grams,
                          values: Self.scaled(best, grams)),
            source: best.source,
            alternatives: found.dropFirst().map {
                .init(fdcID: $0.fdcID, description: $0.description, source: $0.source,
                      kcal: pyRound($0.kcal * grams / 100, 1))
            })
    }

    private static func scaled(_ food: Food, _ grams: Double) -> Nutrients {
        food.per100g.mapValues { $0.map { round2($0 * grams / 100) } }
    }

    // MARK: - search

    /// Descriptors of the plain, unprocessed form of a food.
    static let plain: Set<String> = ["raw", "whole", "plain", "fresh", "nfs"]

    /// Best matches first. USDA names are comma segments: the food alone is
    /// "Grapes, raw" / "Fish, salmon, raw", while a dish that contains it carries
    /// extra words in the food's own segment ("Salmon salad", "Grape leaves").
    /// Ranking: most query words present, fewest extra words sharing a segment
    /// with a query word, fewest extra words overall, most plain descriptors,
    /// custom foods, then bm25. A custom food ranks by its closest name (its
    /// description or one alias), so "whole milk" finds milk before "Acme whole
    /// milk yogurt". When nothing has every word, partial matches come back,
    /// each with `missing` set.
    func search(_ query: String, source: String? = nil, limit: Int = 15) throws -> [Hit] {
        let words = Self.words(query)
        guard !words.isEmpty else { throw Failure.noWords }
        let qstems = Set(words.map(Self.stem))
        let custom = source == nil || source == "custom" ? try searchCustom(qstems) : []
        if source == "custom" {
            return custom.enumerated().sorted { ($0.1.key.0, $0.1.key.1, $0.1.key.2, $0.1.key.3, $0.0) < ($1.1.key.0, $1.1.key.1, $1.1.key.2, $1.1.key.3, $1.0) }
                .prefix(limit).map(\.1.hit)
        }

        var sql = """
            SELECT f.fdc_id, f.description, f.source, f.category, ROUND(f.kcal_100g, 2) AS kcal,
            ROUND(f.protein_g, 2) AS protein_g, ROUND(f.fat_g, 2) AS fat_g, ROUND(f.carb_g, 2) AS carb_g,
            food_fts.rank AS bm25 FROM food_fts JOIN food f ON f.fdc_id = food_fts.rowid
            WHERE food_fts MATCH ? AND f.kcal_100g IS NOT NULL
            """
        if source != nil { sql += " AND f.source = ?" }
        func run(_ match: String) throws -> [(Hit, Double)] {
            try db.rows(sql, [.text(match)] + (source.map { [.text($0)] } ?? [])).map { r in
                (Hit(fdcID: r["fdc_id"]?.int ?? 0, description: r["description"]?.string ?? "",
                     source: r["source"]?.string ?? "", category: r["category"]?.string,
                     kcal: r["kcal"]?.double ?? 0, proteinG: r["protein_g"]?.double ?? 0,
                     fatG: r["fat_g"]?.double ?? 0, carbG: r["carb_g"]?.double ?? 0),
                 r["bm25"]?.double ?? 0)
            }
        }
        var found = try run(words.map { "\"\($0)\"" }.joined(separator: " "))
        if found.isEmpty && words.count > 1 {
            found = try run(words.map { "\"\($0)\"" }.joined(separator: " OR "))
            for i in found.indices {
                let have = Self.words(found[i].0.description.lowercased())
                found[i].0.missing = words.filter { w in !have.contains { $0.hasPrefix(Self.stem(w)) } }
            }
        }

        // custom foods win ties; `order` keeps the found order on equal keys, as
        // Python's stable sort does
        typealias Ranked = (key: Key, custom: Int, bm25: Double, order: Int, hit: Hit)
        let all: [Ranked] = custom.map { ($0.key, 0, 0.0, 0, $0.hit) }
            + found.map { (Self.key(Self.segs($0.0.description), qstems), 1, $0.1, 0, $0.0) }
        let ranked = all.enumerated().map { i, r in (r.key, r.custom, r.bm25, i, r.hit) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3) }.map(\.4)

        // Foundation republishes some foods under a new fdc_id with identical
        // values (e.g. 2263890 / 2346412 "Grapes, red, seedless, raw"); show each once.
        var out: [Hit] = []
        var seen = Set<String>()
        for h in ranked where out.count < limit {
            let ident = "\(h.description.lowercased())|\(h.kcal)|\(h.proteinG)|\(h.fatG)|\(h.carbG)"
            if h.source == "custom" || seen.insert(ident).inserted { out.append(h) }
        }
        return out
    }

    typealias Key = (Int, Int, Int, Int)

    /// Most query words present, fewest extra words sharing a segment with a
    /// query word, fewest extra words overall, most plain descriptors.
    static func key(_ segs: [Set<String>], _ qstems: Set<String>) -> Key {
        let all = segs.reduce(into: Set<String>()) { $0.formUnion($1) }
        let modifiers = segs.filter { !$0.isDisjoint(with: qstems) }.reduce(0) { $0 + $1.subtracting(qstems).count }
        let plain = plain.subtracting(qstems).intersection(all).count
        return (-qstems.intersection(all).count, modifiers, all.subtracting(qstems).subtracting(Self.plain).count, -plain)
    }

    /// A name's comma segments, each as its word stems.
    static func segs(_ text: String) -> [Set<String>] {
        text.split(separator: ",", omittingEmptySubsequences: false).map { Set(words(String($0)).map(stem)) }
    }

    /// Custom foods whose name or aliases hold every query word (as a word
    /// prefix, so 'smoke' finds 'smoked'), each with its rank key by its closest
    /// name, newest first.
    private func searchCustom(_ qstems: Set<String>) throws -> [(key: Key, hit: Hit)] {
        let sortedQ = qstems.sorted()
        // a word a query word is a prefix of counts as that query word
        let asQ = { (w: String) in sortedQ.first { w.hasPrefix($0) } ?? w }
        return try db.rows("SELECT * FROM custom.food WHERE hidden=0 ORDER BY fdc_id").compactMap { r in
            let description = r["description"]?.string ?? "", aliases = r["aliases"]?.string ?? ""
            let words = Self.words("\(description) \(aliases)".lowercased())
            guard qstems.allSatisfy({ q in words.contains { $0.hasPrefix(q) } }) else { return nil }
            let names = [description] + aliases.split(separator: ",").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let best = names.map { n in Self.key(Self.segs(n.lowercased()).map { Set($0.map(asQ)) }, qstems) }.min { $0 < $1 }!
            return ((-qstems.count, best.1, best.2, best.3), Hit(fdcID: r["fdc_id"]?.int ?? 0, description: r["description"]?.string ?? "", source: "custom",
                       category: Self.category[r["kind"]?.string ?? "label"],
                       kcal: round2(r["kcal"]?.double ?? 0), proteinG: round2(r["protein_g"]?.double ?? 0),
                       fatG: round2(r["fat_g"]?.double ?? 0), carbG: round2(r["carb_g"]?.double ?? 0)))
        }
    }

    /// Python's re.findall(r"\w+", s).
    static func words(_ s: String) -> [String] {
        s.matches(of: /\w+/).map { String($0.output) }
    }

    static func stem(_ w: String) -> String {
        let w = w.lowercased()
        return w.hasSuffix("s") && w.count > 3 ? String(w.dropLast()) : w
    }
}

/// Python's round(x, digits): the decimal nearest the exact binary value, ties
/// to even. `(x * 100).rounded() / 100` differs from it whenever `x * 100`
/// itself rounds, so it would not reproduce the server's numbers.
func pyRound(_ x: Double, _ digits: Int) -> Double {
    Double(String(format: "%.\(digits)f", x))!
}

func round2(_ x: Double) -> Double { pyRound(x, 2) }

/// Python's repr() of a string, as the server's error messages quote names.
func pyRepr(_ s: String) -> String {
    let q = s.contains("'") && !s.contains("\"") ? "\"" : "'"
    var body = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    if q == "'" { body = body.replacingOccurrences(of: "'", with: "\\'") }
    return q + body + q
}
