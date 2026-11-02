import Foundation

/// The household's own foods: packaged products typed in from their nutrition
/// label, and recipes computed from their ingredients. A port of the nutrition
/// server's add_custom_food / add_recipe / list_custom_foods /
/// remove_custom_food; BiteLogTests checks it against that server's answers.
extension FoodDB {
    /// One custom food as the foods list shows it: its serving and the values
    /// for one serving.
    struct Custom: Equatable {
        let fdcID: Int
        let kind: String
        let description: String
        let aliases: String
        let servingLabel: String?
        /// Rounded to 0.1 g.
        let servingG: Double
        /// A recipe's {text, servings, cooked_g, ingredients}.
        let recipe: JSON?
        let perServing: Nutrients
    }

    struct RecipeLine: Equatable {
        let fdcID: Int
        let grams: Double
        var said: String? = nil
    }

    /// A saved recipe: the new food, each ingredient's numbers, and the totals.
    struct SavedRecipe: Equatable {
        let food: Food
        let ingredients: [JSON]
        let totals: [String: Double]
    }

    func customFoods() throws -> [Custom] {
        try db.rows("SELECT * FROM custom.food WHERE hidden=0 ORDER BY description COLLATE NOCASE").map { r in
            let serving = r["serving_g"]?.double ?? 0
            return Custom(fdcID: r["fdc_id"]?.int ?? 0, kind: r["kind"]?.string ?? "label",
                          description: r["description"]?.string ?? "", aliases: r["aliases"]?.string ?? "",
                          servingLabel: r["serving_label"]?.string, servingG: pyRound(serving, 1),
                          recipe: try r["recipe"]?.string.map { try JSON.parse($0) },
                          perServing: Dictionary(uniqueKeysWithValues: Self.nutrientKeys.map { k in
                              (k, r[k]?.double.map { round2($0 * serving / 100) })
                          }))
        }
    }

    /// A product from its label: the label's values per serving, stored per 100 g.
    /// Rejects calories that don't fit the macros (4/9/4 kcal per g), which
    /// catches per-serving vs per-100 g mix-ups. `replaces` hides an older
    /// version (an edit).
    func addCustomFood(name: String, aliases: String = "", servingLabel: String? = nil, servingG: Double,
                       perServing: Nutrients, replaces: Int? = nil) throws -> Food {
        try checkName(name)
        guard servingG > 0 else { throw Failure.invalid("serving_g must be more than 0") }
        func value(_ k: String) -> Double? { perServing[k] ?? nil }
        for k in ["kcal", "protein_g", "fat_g", "carb_g"] where value(k) == nil {
            throw Failure.invalid("\(k) is required")
        }
        for (k, v) in perServing { if let v, v < 0 { throw Failure.invalid("\(k) must be 0 or more") } }
        let kcal = value("kcal")!, p = value("protein_g")!, f = value("fat_g")!, c = value("carb_g")!
        let fromMacros = 4 * p + 9 * f + 4 * c
        if abs(kcal - fromMacros) > max(15, 0.2 * kcal) {
            throw Failure.invalid("\(Self.g(kcal)) kcal doesn't fit the macros (\(Self.g(p)) g protein, \(Self.g(f)) g fat, "
                                  + "\(Self.g(c)) g carb = ~\(String(format: "%.0f", fromMacros)) kcal); check the label")
        }
        let per = Dictionary(uniqueKeysWithValues: Self.nutrientKeys.map { k in (k, value(k).map { $0 * 100 / servingG }) })
        try checkReplaces(replaces)
        return try food(insert(name: name, aliases: aliases, servingLabel: servingLabel, servingG: servingG, per: per,
                               replaces: replaces))
    }

    /// A recipe as a food, from its ingredients (as added to the pot, water and
    /// broth included). Per 100 g = totals / cooked_g when the dish was weighed,
    /// else totals / the summed ingredient grams; '1 serving' = that weight /
    /// servings. `replaces` hides an older version (an edit).
    func addRecipe(name: String, aliases: String = "", text: String = "", servings: Double = 1, cookedG: Double? = nil,
                   ingredients: [RecipeLine], replaces: Int? = nil) throws -> SavedRecipe {
        try checkName(name)
        guard !ingredients.isEmpty else { throw Failure.invalid("ingredients is empty") }
        guard servings > 0 else { throw Failure.invalid("servings must be more than 0") }
        if let c = cookedG, c <= 0 { throw Failure.invalid("cooked_g must be more than 0") }
        let calc = try nutrition(ingredients.map { Amount(fdcID: $0.fdcID, grams: $0.grams) })
        let basis = cookedG ?? ingredients.reduce(0) { $0 + $1.grams }
        let per = Dictionary(uniqueKeysWithValues: Self.nutrientKeys.map { k in (k, calc.totals[k].map { $0 * 100 / basis }) })
        let lines: [JSON] = zip(ingredients, calc.items).map { i, n in
            ["said": i.said.map(JSON.string) ?? .null, "fdc_id": .number(Double(n.fdcID)), "description": .string(n.description),
             "grams": .number(n.grams), "kcal": num(n.values["kcal"]), "protein_g": num(n.values["protein_g"]),
             "fat_g": num(n.values["fat_g"]), "carb_g": num(n.values["carb_g"])]
        }
        try checkReplaces(replaces)
        let recipe: JSON = ["text": .string(text), "servings": .number(servings),
                            "cooked_g": cookedG.map(JSON.number) ?? .null, "ingredients": .array(lines)]
        let id = try insert(name: name, aliases: aliases, servingLabel: "1 of \(Self.g(servings)) servings",
                            servingG: basis / servings, per: per, kind: "recipe", recipe: recipe, replaces: replaces)
        return SavedRecipe(food: try food(id), ingredients: lines, totals: calc.totals)
    }

    /// Hides it from search; log items that use it keep working.
    func removeCustomFood(_ fdcID: Int) throws {
        guard fdcID < 0, !(try db.rows("SELECT 1 FROM custom.food WHERE fdc_id=?", [.int(Int64(fdcID))]).isEmpty) else {
            throw Failure.invalid("no custom food with fdc_id \(fdcID)")
        }
        try db.run("UPDATE custom.food SET hidden=1 WHERE fdc_id=?", [.int(Int64(fdcID))])
    }

    private func insert(name: String, aliases: String, servingLabel: String?, servingG: Double, per: Nutrients,
                        kind: String = "label", recipe: JSON? = nil, replaces: Int? = nil) throws -> Int {
        try db.transaction {
            let lowest = try db.rows("SELECT MIN(fdc_id) AS m FROM custom.food").first?["m"]?.int ?? 0
            let id = min(-1, lowest - 1)
            let cols = ["fdc_id", "description", "aliases", "serving_label", "serving_g", "kind", "recipe"] + Self.nutrientKeys
            let args: [SQLite.Value] = [.int(Int64(id)), .text(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                                        .text(aliases.trimmingCharacters(in: .whitespacesAndNewlines)),
                                        servingLabel.map(SQLite.Value.text) ?? .null, .real(servingG), .text(kind),
                                        try recipe.map { .text(try $0.text()) } ?? .null]
                + Self.nutrientKeys.map { k in (per[k] ?? nil).map(SQLite.Value.real) ?? .null }
            try db.run("INSERT INTO custom.food(\(cols.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ",")))",
                       args)
            if let r = replaces { try db.run("UPDATE custom.food SET hidden=1 WHERE fdc_id=?", [.int(Int64(r))]) }
            return id
        }
    }

    private func checkReplaces(_ replaces: Int?) throws {
        if let r = replaces, try db.rows("SELECT 1 FROM custom.food WHERE fdc_id=? AND fdc_id < 0", [.int(Int64(r))]).isEmpty {
            throw Failure.invalid("replaces: no custom food with fdc_id \(r)")
        }
    }

    private func checkName(_ name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(n.count) else { throw Failure.invalid("name must be 2 to 120 characters") }
    }

    /// Python's format(x, "g").
    static func g(_ x: Double) -> String { String(format: "%g", x) }
}

private func num(_ v: Double??) -> JSON { (v ?? nil).map(JSON.number) ?? .null }

// MARK: - export and load

extension FoodDB {
    /// What a loaded export's custom_foods.db must have.
    static let requiredCustom = ["food": ["fdc_id", "description", "serving_g"]]

    /// A standalone copy of the custom foods (the export's custom_foods.db).
    func copyCustom(to url: URL) throws { try db.copy("custom", to: url.path) }

    /// Replaces every custom food with those in another custom foods file.
    func replaceCustom(from url: URL) throws { try db.replaceRows("custom", tables: ["food"], from: url.path) }

    /// Checks a loaded export's custom foods; returns how many show in search.
    static func checkCustom(_ url: URL) throws -> Int {
        let db = try SQLite.checked(url.path, required: requiredCustom, what: "The foods list")
        guard try db.rows("SELECT 1 FROM food WHERE fdc_id >= 0 LIMIT 1").isEmpty else {
            throw Failure.invalid("The foods list in this file has foods with USDA ids.")
        }
        return try db.rows("SELECT COUNT(*) AS n FROM food WHERE hidden=0").first?["n"]?.int ?? 0
    }
}
