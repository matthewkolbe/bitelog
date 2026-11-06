import Foundation
import Testing
@testable import BiteLog

/// The nutrition math against the Python code's answers for the same inputs:
/// nutrition_golden.json, written by ios/make_golden.py (server.py's nutrition,
/// lookup and get_food; brain.py's version_adjust and compute). Numbers must be
/// equal, not close: the phone logs exactly what the web app would.
@MainActor
struct NutritionTests {
    let db: FoodDB
    let golden: [String: [[String: Any]]]

    init() throws {
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID()).db")
        db = try FoodDB(usda: try #require(Bundle.main.url(forResource: "fdc", withExtension: "db")), custom: custom)
        let url = try #require(Bundle(for: Marker.self).url(forResource: "nutrition_golden", withExtension: "json"))
        golden = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[String: Any]]])
    }

    @Test func nutrition() throws {
        for c in golden["nutrition"]! {
            let items = (c["items"] as! [[String: Any]]).map(amount)
            try check(c) { try db.nutrition(items) } match: { meal, want in
                let want = want as! [String: Any]
                let wantItems = want["items"] as! [[String: Any]]
                #expect(meal.items.count == wantItems.count)
                for (got, w) in zip(meal.items, wantItems) { expectScaled(got, w) }
                #expect(meal.totals == want["totals"] as! [String: Double])
            }
        }
    }

    @Test func lookup() throws {
        for c in golden["lookup"]! {
            try check(c) {
                try db.lookup(c["food"] as! String, grams: c["grams"] as! Double, alternatives: c["alternatives"] as! Int)
            } match: { got, want in
                let want = want as! [String: Any]
                let m = want["match"] as! [String: Any]
                expectScaled(got.match, m)
                #expect(got.source == m["source"] as! String)
                let alts = want["alternatives"] as! [[String: Any]]
                #expect(got.alternatives.map(\.fdcID) == alts.map { $0["fdc_id"] as! Int })
                #expect(got.alternatives.map(\.description) == alts.map { $0["description"] as! String })
                #expect(got.alternatives.map(\.source) == alts.map { $0["source"] as! String })
                #expect(got.alternatives.map(\.kcal) == alts.map { $0["kcal"] as! Double })
            }
        }
    }

    @Test func allNutrients() throws {
        for c in golden["all_nutrients"]! {
            try check(c) { try db.allNutrients(c["fdc_id"] as! Int) } match: { got, want in
                let rows = want as! [[String: Any]]
                #expect(got == rows.map { .init(name: $0["name"] as! String, amount: $0["amount"] as! Double,
                                               unit: $0["unit"] as! String) })
            }
        }
    }

    @Test func versionAdjust() throws {
        for c in golden["version_adjust"]! {
            try check(c) { try db.adjust(version(c["version"]), for: c["fdc_id"] as! Int) } match: { got, want in
                #expect(got == adjust(want))
            }
        }
    }

    @Test func compute() throws {
        for c in golden["compute"]! {
            let items = (c["items"] as! [[String: Any]]).map { (amount($0), $0["adjust"].map(adjust)) }
            try check(c) { try db.compute(items) } match: { got, want in
                let rows = want as! [[String: Any]]
                #expect(got.count == rows.count)
                for (g, w) in zip(got, rows) { expectScaled(g, w) }
            }
        }
    }

    /// Custom foods and recipes, in the server's order on an empty custom
    /// database: the same ids, numbers, errors and lists.
    @Test func customFoods() throws {
        for c in golden["custom"]! {
            let a = c["args"] as! [String: Any]
            func num(_ k: String) -> Double? { a[k] as? Double }
            switch c["call"] as! String {
            case "add_custom_food":
                try check(c) {
                    try db.addCustomFood(name: a["name"] as! String, aliases: a["aliases"] as? String ?? "",
                                         servingLabel: a["serving_label"] as? String, servingG: num("serving_g")!,
                                         perServing: Dictionary(uniqueKeysWithValues: FoodDB.nutrientKeys.map { ($0, num($0)) }),
                                         replaces: a["replaces"] as? Int)
                } match: { got, want in expectFood(got, want as! [String: Any]) }
            case "add_recipe":
                try check(c) {
                    try db.addRecipe(name: a["name"] as! String, aliases: a["aliases"] as? String ?? "",
                                     text: a["text"] as? String ?? "", cookedG: num("cooked_g"),
                                     ingredients: (a["ingredients"] as! [[String: Any]]).map {
                                         .init(fdcID: $0["fdc_id"] as! Int, grams: $0["grams"] as! Double, said: $0["said"] as? String)
                                     },
                                     replaces: a["replaces"] as? Int)
                } match: { got, want in
                    let w = want as! [String: Any]
                    expectFood(got.food, w)
                    #expect(got.ingredients == (w["ingredients"] as! [Any]).map(json))
                    #expect(got.totals == w["totals"] as! [String: Double])
                }
            case "list_custom_foods":
                try check(c) { try db.customFoods() } match: { got, want in
                    let rows = want as! [[String: Any]]
                    #expect(got.map(\.fdcID) == rows.map { $0["fdc_id"] as! Int })
                    for (g, w) in zip(got, rows) {
                        #expect(g.kind == w["kind"] as! String)
                        #expect(g.description == w["description"] as! String)
                        #expect(g.aliases == w["aliases"] as! String)
                        #expect(g.servingLabel == w["serving_label"] as? String)
                        #expect(g.servingG == w["serving_g"] as! Double)
                        #expect(g.recipe == w["recipe"].map(json))
                        for k in FoodDB.nutrientKeys { #expect(g.perServing[k] == .some(w[k] as? Double), "\(g.description) \(k)") }
                    }
                }
            case "search_foods":
                try check(c) {
                    try db.search(a["query"] as! String, source: a["source"] as? String, limit: a["limit"] as? Int ?? 15)
                } match: { got, want in
                    #expect(got.map(\.fdcID) == (want as! [[String: Any]]).map { $0["fdc_id"] as! Int })
                }
            case "remove_custom_food":
                try check(c) { try db.removeCustomFood(a["fdc_id"] as! Int) } match: { _, _ in }
            default:
                Issue.record("unknown call \(c["call"]!)")
            }
        }
    }

    private func expectFood(_ got: FoodDB.Food, _ want: [String: Any]) {
        #expect(got.fdcID == want["fdc_id"] as! Int)
        #expect(got.description == want["description"] as! String)
        #expect(got.source == want["source"] as! String)
        #expect(got.category == want["category"] as? String)
        let per = want["per_100g"] as! [String: Any]
        for k in FoodDB.nutrientKeys { #expect(got.per100g[k] == .some(per[k] as? Double), "\(got.description) \(k)") }
        #expect(got.portions.map(\.grams) == (want["portions"] as! [[String: Any]]).map { $0["gram_weight"] as! Double })
    }

    /// Foundation's parse of the golden JSON, as our JSON value.
    private func json(_ v: Any) -> JSON {
        try! JSON.parse(JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
    }

    @Test func adjustRoundTripsThroughJSON() throws {
        let a = Nutrition.Adjust(why: "2%", per100g: ["fat_g": 2], factors: ["fat_g": 0.4])
        #expect(try JSONDecoder().decode(Nutrition.Adjust.self, from: JSONEncoder().encode(a)) == a)
    }

    // MARK: - helpers

    /// A golden case holds either `result` or the `error` message the model would read.
    private func check<T>(_ c: [String: Any], _ run: () throws -> T,
                          match: (T, Any) -> Void) throws {
        if let message = c["error"] as? String {
            let error = #expect(throws: (any Error).self) { _ = try run() }
            #expect(error.map { String(describing: $0) } == message)
        } else {
            match(try run(), try #require(c["result"]))
        }
    }

    private func amount(_ d: [String: Any]) -> FoodDB.Amount {
        .init(fdcID: d["fdc_id"] as! Int, grams: d["grams"] as? Double, portion: d["portion"] as? String,
              quantity: d["quantity"] as? Double ?? 1, amount: (d["amount"] as? NSNumber)?.doubleValue,
              unit: d["unit"] as? String)
    }

    private func version(_ v: Any?) -> Nutrition.Version {
        let d = v as! [String: Any]
        return .init(why: d["why"] as! String, per100g: d["per_100g"] as! [String: Double])
    }

    /// brain.py's adjust: why, per_100g, and the factors as the remaining keys.
    private func adjust(_ v: Any) -> Nutrition.Adjust {
        let d = v as! [String: Any]
        return .init(why: d["why"] as! String, per100g: d["per_100g"] as! [String: Double],
                     factors: d.filter { $0.key != "why" && $0.key != "per_100g" }.mapValues { $0 as! Double })
    }

    private func expectScaled(_ got: FoodDB.Scaled, _ want: [String: Any]) {
        #expect(got.fdcID == want["fdc_id"] as! Int)
        #expect(got.description == want["description"] as! String)
        #expect(got.grams == want["grams"] as! Double)
        for k in FoodDB.nutrientKeys {
            #expect(got.values[k] == .some(want[k] as? Double), "\(got.description) \(k)")
        }
    }
}

private final class Marker {}
