import Foundation

/// Amounts said in a unit, as the nutrition server converts them. Weights
/// convert by fixed factors; volumes by the food's own volume portions (a cup of
/// flour isn't a cup of milk); calories by the food's calories per gram.
/// Anything else ("a fist", "a bowl") is the model's estimate, in grams.
extension FoodDB {
    nonisolated static let gramsPer: [String: Double] = [
        "g": 1, "gram": 1, "grams": 1, "kg": 1000, "kilogram": 1000, "kilograms": 1000,
        "mg": 0.001, "milligram": 0.001, "milligrams": 0.001,
        "oz": 28.349523125, "ounce": 28.349523125, "ounces": 28.349523125,
        "lb": 453.59237, "lbs": 453.59237, "pound": 453.59237, "pounds": 453.59237,
    ]
    nonisolated static let mlPer: [String: Double] = [
        "ml": 1, "milliliter": 1, "milliliters": 1, "millilitre": 1, "millilitres": 1,
        "l": 1000, "liter": 1000, "liters": 1000, "litre": 1000, "litres": 1000,
        "tsp": 4.92892159375, "teaspoon": 4.92892159375, "teaspoons": 4.92892159375,
        "tbsp": 14.78676478125, "tablespoon": 14.78676478125, "tablespoons": 14.78676478125,
        "cup": 236.5882365, "cups": 236.5882365,
        "fl oz": 29.5735295625, "fluid ounce": 29.5735295625, "fluid ounces": 29.5735295625,
        "pint": 473.176473, "pints": 473.176473, "quart": 946.352946, "quarts": 946.352946,
        "gallon": 3785.411784, "gallons": 3785.411784,
    ]
    nonisolated static let kcalUnits: Set<String> = ["kcal", "calorie", "calories", "cal"]

    /// A portion label that is a volume: "1 cup", "0.5 cup, chopped", "1 fl oz (no ice)".
    nonisolated(unsafe) static let volumeLabel = try! NSRegularExpression(
        pattern: #"^(\d+(?:\.\d+)?)\s+("#
            + mlPer.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            + #")\b\s*(.*)$"#)

    /// "Tbsp.", " fl. oz " -> "tbsp", "fl oz".
    static func unitKey(_ unit: String) -> String {
        unit.lowercased().replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isKcal(_ unit: String?) -> Bool { unit.map { kcalUnits.contains(unitKey($0)) } ?? false }

    /// (ml, rest) for a volume portion label, else nil.
    static func volume(_ label: String) -> (ml: Double, rest: String)? {
        let s = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = s as NSString
        guard let m = volumeLabel.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let n = Double(ns.substring(with: m.range(at: 1))), let per = mlPer[ns.substring(with: m.range(at: 2))]
        else { return nil }
        return (n * per, ns.substring(with: m.range(at: 3)))
    }

    /// The food's density from its volume portions: the one named exactly, else
    /// the plain ones ("1 cup"), else those with a parenthetical ("1 cup (8 fl oz)"),
    /// else the rest ("1 cup, chopped"), as long as the chosen ones agree within
    /// 10%. The form only matters when they don't.
    static func gramsPerML(_ food: Food, portion: String?) throws -> Double {
        let vols: [(label: String, density: Double, rest: String)] = food.portions.compactMap { p in
            guard p.grams != 0, let v = volume(p.label) else { return nil }
            return (p.label, p.grams / v.ml, v.rest)
        }
        let labels = { (vs: [(label: String, density: Double, rest: String)]) in
            "[" + vs.map { pyRepr($0.label) }.joined(separator: ", ") + "]"
        }
        let at = "fdc_id \(food.fdcID) (\(food.description))"
        if let portion {
            let want = portion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let hit = vols.first(where: { $0.label.lowercased() == want }) { return hit.density }
        }
        guard !vols.isEmpty else { throw Failure.invalid("\(at) has no volume portions to measure by; estimate grams") }
        for tier in [vols.filter { $0.rest.isEmpty }, vols.filter { $0.rest.hasPrefix("(") }, vols] where !tier.isEmpty {
            let ds = tier.map(\.density)
            if ds.max()! > 1.1 * ds.min()! {
                throw Failure.invalid("\(at): its volume portions differ by form; add portion, exactly one of \(labels(tier))")
            }
            return ds[0]
        }
        fatalError("unreachable: the last tier is every volume portion")
    }

    /// Grams of one, for a count said as a unit: "large" -> the "1 large"
    /// portion, "slices" -> "1 slice", "small" -> "1 small (5-1/2\" long)".
    static func count(_ food: Food, _ u: String) -> Double? {
        let names = [u] + (u.hasSuffix("es") ? [String(u.dropLast(2))] : []) + (u.hasSuffix("s") ? [String(u.dropLast())] : [])
        let labels = food.portions.filter { $0.grams != 0 }.map { ($0.label.lowercased(), $0.grams) }
        for name in names {
            if let hit = labels.first(where: { $0.0 == "1 \(name)" }) { return hit.1 }
        }
        for name in names {
            if let hit = labels.first(where: { $0.0.hasPrefix("1 \(name) (") || $0.0.hasPrefix("1 \(name),") }) { return hit.1 }
        }
        return nil
    }

    /// Grams for an amount said in a unit: a weight, a volume, calories, or a
    /// count of one of the food's portions. A unit that is none of these ("a
    /// mug") is the model's to estimate: its grams, when it gave them.
    static func grams(_ food: Food, amount: Double, unit: String, portion: String?, grams: Double? = nil) throws -> Double {
        let u = unitKey(unit)
        if let g = gramsPer[u] { return amount * g }
        if let ml = mlPer[u] { return amount * ml * (try gramsPerML(food, portion: portion)) }
        if kcalUnits.contains(u) {
            guard let kcal = food.per100g["kcal"] ?? nil, kcal != 0 else {
                throw Failure.invalid("fdc_id \(food.fdcID) (\(food.description)) has no calories to measure by; give grams")
            }
            return amount * 100 / kcal
        }
        if let one = count(food, u) { return amount * one }
        if let grams { return grams }
        let labels = food.portions.isEmpty ? "it has none"
            : "[" + food.portions.map { pyRepr($0.label) }.joined(separator: ", ") + "]"
        throw Failure.invalid("unknown unit \(pyRepr(unit)) for fdc_id \(food.fdcID) (\(food.description)): use a weight "
                              + "(g, oz, lb, kg), a volume (tsp, tbsp, cup, fl oz, ml, l), kcal, a portion of this food "
                              + "(\(labels)), or estimate grams")
    }

    /// Nil when an item has an amount. Used in this order: amount with unit (as
    /// said), else portion x quantity, else grams; so grams the model worked out
    /// alongside the unit it heard are ignored, and an amount with no unit is.
    /// The nutrition server's amount_error.
    static func amountError(grams: Double?, portion: String?, amount: Double?, unit: String?) -> String? {
        if let unit, amount == nil { return "unit \(pyRepr(unit)) needs an amount: how many of it" }
        if unit == nil && portion == nil && grams == nil {
            return amount.map { "amount \(String(format: "%g", $0)) has no unit: add unit ('g' if it's grams)" }
                ?? "give grams, a portion, or amount with unit"
        }
        return nil
    }
}
