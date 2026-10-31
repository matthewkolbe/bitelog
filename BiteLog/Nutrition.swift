import Foundation

/// Versions of a food: what the user ate when it differs from the closest
/// database entry (90% cacao vs a 70-85% bar, a recipe with less oil). A port of
/// brain.py's version_adjust / apply_adjust / compute; BiteLogTests checks it
/// against that code's answers.
///
/// The model states its version's per-100 g values; the app turns them into
/// factors on the entry (the item's `Adjust`) and scales the entry's numbers by
/// them. The model never sends factors, and every number logged is the
/// database's, scaled only by those factors (calories follow the macros, 4/9/4).
enum Nutrition {
    /// Nutrients a version may change.
    static let adjustable = ["protein_g", "fat_g", "carb_g", "sugar_g", "fiber_g", "sat_fat_g", "sodium_mg"]
    /// A factor carries to a part the model didn't state: saturated fat is part of fat.
    static let partOf = ["sat_fat_g": "fat_g"]
    /// In brain.py's order, so the calorie sum adds up in the same order.
    static let kcalPerG: [(String, Double)] = [("protein_g", 4), ("fat_g", 9), ("carb_g", 4)]

    /// What the model sends: why, and the version's per-100 g values that differ.
    struct Version: Equatable, Codable {
        var why: String
        var per100g: [String: Double]
        enum CodingKeys: String, CodingKey { case why, per100g = "per_100g" }
    }

    /// What the item stores: the version, plus a factor on the entry for each
    /// nutrient the version gives (none for a nutrient the entry has 0 of).
    struct Adjust: Equatable, Codable {
        var why: String
        var per100g: [String: Double]
        var factors: [String: Double]
        enum CodingKeys: String, CodingKey { case why, per100g = "per_100g", factors }
    }

    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ m: String) { description = m }
    }

    /// The model's version of `food` -> the adjust stored on the item. `Invalid`
    /// says what to fix, in brain.py's words.
    static func adjust(_ version: Version, on food: FoodDB.Food) throws -> Adjust {
        let why = version.why.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else {
            throw Invalid("version needs why: the entry's numbers per 100 g and the user's version worked out")
        }
        guard !version.per100g.isEmpty else {
            throw Invalid("version.per_100g is empty; leave version out when the entry matches")
        }
        let bad = Set(version.per100g.keys).subtracting(adjustable)
        guard bad.isEmpty else {
            throw Invalid("version.per_100g can only give \(adjustable.joined(separator: ", ")) "
                          + "(not \(bad.sorted().joined(separator: ", ")))")
        }
        var factors: [String: Double] = [:]
        for k in adjustable {
            guard let v = version.per100g[k] else { continue }
            guard v >= 0 else { throw Invalid("version.per_100g.\(k) must be a number of 0 or more") }
            let base = (food.per100g[k] ?? nil) ?? 0
            if base == 0 {
                if v > 0 {
                    throw Invalid("entry \(food.fdcID) has no \(k) to scale; pick an entry that has some, "
                                  + "or log what adds it as its own item")
                }
                continue
            }
            factors[k] = pyRound(v / base, 4)
        }
        return Adjust(why: why, per100g: version.per100g, factors: factors)
    }

    /// Numbers `n` scaled by the adjust's factors; calories move with the macros.
    static func apply(_ adjust: Adjust?, to n: FoodDB.Nutrients) -> FoodDB.Nutrients {
        guard let adjust else { return n }
        func get(_ d: FoodDB.Nutrients, _ k: String) -> Double? { d[k] ?? nil }
        var out = n
        var factors = adjust.factors.filter { adjustable.contains($0.key) }
        for (part, whole) in partOf where factors[part] == nil {
            if let f = factors[whole] { factors[part] = f }
        }
        for (k, f) in factors {
            if let v = get(n, k) { out.updateValue(v * f, forKey: k) }
        }
        // sugar and fiber are carbohydrate; never more of them than the carbs left
        if let carb = get(out, "carb_g") {
            for part in ["sugar_g", "fiber_g"] {
                if let v = get(out, part) { out.updateValue(min(v, carb), forKey: part) }
            }
        }
        var change = 0.0
        for (k, c) in kcalPerG {
            if let before = get(n, k), let after = get(out, k) { change += c * (after - before) }
        }
        out.updateValue(max(0, (get(n, "kcal") ?? 0) + change), forKey: "kcal")
        return out
    }
}

extension FoodDB {
    /// The database's numbers for each amount, scaled by its adjust.
    func compute(_ items: [(amount: Amount, adjust: Nutrition.Adjust?)]) throws -> [Scaled] {
        try zip(nutrition(items.map(\.amount)).items, items).map { scaled, it in
            var s = scaled
            s.values = Nutrition.apply(it.adjust, to: s.values)
            return s
        }
    }
}

extension FoodDB {
    /// `Nutrition.adjust` for the food with this id.
    func adjust(_ version: Nutrition.Version, for fdcID: Int) throws -> Nutrition.Adjust {
        try Nutrition.adjust(version, on: food(fdcID))
    }
}
