import Foundation
import Testing
@testable import BiteLog

/// FoodDB is a port of the Bite Log web app's nutrition server; these are that server's
/// answers (its `_search(c, q, None, 8)` and `get()`, run with an empty custom
/// database), so the phone ranks and reports foods exactly as the web app does.
/// Regenerate them if the server's search changes or fdc.db is rebuilt.
@MainActor
struct FoodDBTests {
    let db: FoodDB

    init() throws {
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID()).db")
        let usda = try #require(Bundle.main.url(forResource: "fdc", withExtension: "db"))
        db = try FoodDB(usda: usda, custom: custom)
    }

    nonisolated static let expected: [String: [(Int, [String]?)]] = [
        "grapes": [(2709237, nil), (173040, nil), (321360, nil), (2263890, nil), (2263891, nil), (2709375, nil), (174682, nil), (174684, nil)],
        "greek yogurt whole plain": [(171309, nil), (2705422, nil), (171304, nil), (2259794, nil)],
        "roasted chicken thighs": [(172388, nil), (173625, nil), (174500, nil), (174505, nil), (2706029, nil), (2706030, nil), (174496, nil), (174503, nil)],
        "white miso": [(2707439, ["white"]), (172183, ["miso"]), (169251, ["miso"]), (1104962, ["miso"]), (2710689, ["miso"]), (2710696, ["miso"]), (2707598, ["miso"]), (2706427, ["miso"])],
        "dark chocolate": [(170271, nil), (170272, nil), (170273, nil), (170274, nil), (2710336, nil), (2710335, nil), (168805, nil), (169592, nil)],
        "salmon": [(2706284, nil), (2706285, nil), (173688, nil), (173689, nil), (173691, nil), (175138, nil), (2706287, nil), (2706289, nil)],
        "oats dry": [(171661, nil), (173904, nil), (171664, nil), (173920, nil), (172989, nil), (174640, nil), (174626, nil)],
        "olive oil": [(2710186, nil), (171413, nil), (167737, nil), (171443, nil), (2710221, nil), (2747652, nil)],
        "scallion green onion": [(2709794, ["scallion"]), (2709953, ["scallion"]), (170006, ["scallion"]), (170462, ["scallion"]), (170005, ["green"]), (2709829, ["scallion"]), (2709795, ["scallion", "green"]), (170000, ["scallion", "green"])],
        "eggs scrambled": [(172187, nil), (169904, nil), (173272, nil), (2707290, nil), (2707291, nil), (2707292, nil), (2707298, nil), (2707300, nil)],
    ]

    @Test(arguments: Array(expected.keys))
    func searchMatchesServer(query: String) throws {
        let got = try db.search(query, limit: 8)
        let want = try #require(Self.expected[query])
        #expect(got.map(\.fdcID) == want.map(\.0))
        #expect(got.map(\.missing) == want.map(\.1))
    }

    @Test func getMatchesServer() throws {
        let f = try db.food(2263890)
        #expect(f.description == "Grapes, red, seedless, raw")
        #expect(f.source == "foundation")
        #expect(f.category == "Fruits and Fruit Juices")
        #expect(f.per100g["kcal"] == 77.15)
        #expect(f.per100g["carb_g"] == 20.2)
        #expect(f.per100g["sodium_mg"] == 7.0)
        #expect(f.per100g["fiber_g"] == .some(nil))
        #expect(f.portions.isEmpty)
    }

    @Test func noWordsIsAnError() {
        #expect(throws: FoodDB.Failure.self) { try db.search("  ,, ") }
    }
}
