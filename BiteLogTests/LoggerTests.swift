import Foundation
import Testing
import UIKit
@testable import BiteLog

/// The tool loop and log_food against a scripted model: what the model is
/// sent, what each tool answers, and what ends up in the log.
@MainActor
struct LoggerTests {
    let foods: FoodDB
    let log: LogDB
    let logger: Logger

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
        foods = try FoodDB(usda: try #require(Bundle.main.url(forResource: "fdc", withExtension: "db")),
                           custom: tmp.appendingPathComponent("custom-\(UUID()).db"))
        log = try LogDB(path: tmp.appendingPathComponent("log-\(UUID()).db").path)
        logger = Logger(foods: foods, log: log, brain: try Brain.bundled(), client: LLMClient(),
                        profiles: try ProfileStore(file: tmp.appendingPathComponent("p-\(UUID()).json")))
    }

    /// A model that answers with these tool calls in turn, recording what it was sent.
    final class Script {
        var replies: [[(String, String)]]
        var requests: [LLM.Request] = []
        var text: [String] = []
        var beforeReply: ((Int) throws -> Void)?
        init(_ replies: [[(String, String)]]) { self.replies = replies }

        func send(_ req: LLM.Request, _ onWait: (Bool) -> Void) throws -> LLM.Reply {
            requests.append(req)
            try beforeReply?(requests.count)
            let calls = replies.isEmpty ? [] : replies.removeFirst()
            return LLM.Reply(text: calls.isEmpty ? "I think that's it." : "",
                             calls: calls.enumerated().map { .init(id: "c\(requests.count)-\($0)", name: $1.0, arguments: $1.1) },
                             native: nil, usage: nil)
        }

        /// The tool results sent back in request n (1-based), parsed.
        func results(_ n: Int) throws -> [JSON] {
            try requests[n - 1].messages.compactMap { if case .tool(_, let c) = $0 { try JSON.parse(c) } else { nil } }
        }
    }

    func run(_ text: String, _ script: Script, at date: Date = Date()) async throws -> LogDB.Entry {
        let id = try log.addEntry(text: text, at: date)
        try await logger.run(id) { try script.send($0, $1) }
        return try #require(try log.entry(id))
    }

    @Test func searchThenLog() async throws {
        let s = Script([
            [("search_foods", #"{"query": "grapes red seedless"}"#)],
            [("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 130, "basis": "weighed"}], "#
                + #""meal": "snack", "summary": "red seedless, raw"}"#)],
        ])
        let e = try await run("130 g of red grapes", s)
        #expect(e.status == .done)
        #expect(e.reply == "red seedless, raw")
        #expect(e.meal == "snack")
        #expect(e.items.map(\.description) == ["Grapes, red, seedless, raw"])
        #expect(e.items[0].values["kcal"] == 100.3)
        #expect(e.items[0].values["fiber_g"] == .some(nil))

        let first = s.requests[0]
        #expect(first.tools.map(\.name) == ["search_foods", "lookup", "get_food", "log_food", "nothing_to_log"])
        #expect(first.messages.first == .system(logger.brain.system))
        guard case .user(let parts) = first.messages[1], case .text(let said) = parts[0] else {
            Issue.record("no user message"); return
        }
        #expect(said.hasPrefix("Entry time: "))
        #expect(said.hasSuffix("(user's local time).\nTyped: 130 g of red grapes"))
        let hits = try #require(try s.results(2).first?.array)
        #expect(hits.contains { $0["fdc_id"] == 2263890 })
    }

    @Test func logFoodErrorsGoBackToTheModel() async throws {
        let s = Script([
            [("log_food", #"{"items": [{"fdc_id": 172187, "said": "eggs", "grams": 100, "portion": "1 large", "basis": "portion"}], "summary": ""}"#)],
            [("log_food", #"{"items": [{"fdc_id": 172187, "said": "eggs", "portion": "1 slice", "basis": "portion"}], "summary": ""}"#)],
            [("log_food", #"{"items": [{"fdc_id": 172187, "said": "eggs", "portion": "1 large", "quantity": 2, "basis": "portion"}], "summary": "scrambled"}"#)],
        ])
        let e = try await run("two scrambled eggs", s)
        #expect(try s.results(2) == [["error": "item 0 (eggs): give exactly one of grams or portion"]])
        let portionError = try #require(try s.results(3).last?["error"]?.string)
        #expect(portionError.hasPrefix("Error executing tool nutrition: fdc_id 172187 (Egg, whole, cooked, scrambled) has no portion '1 slice'"))
        #expect(e.status == .done)
        #expect(e.items[0].grams == 122)
        #expect(e.items[0].values["kcal"] == 181.78)
    }

    @Test func versionScalesTheEntry() async throws {
        let s = Script([[("log_food", #"""
            {"items": [{"fdc_id": 170273, "said": "90% dark chocolate", "grams": 30, "basis": "weighed",
              "version": {"why": "90% cacao", "per_100g": {"fat_g": 50, "carb_g": 32.1, "sugar_g": 14}}}],
             "summary": "90% vs the 70-85% entry"}
            """#)]])
        let e = try await run("30 g of 90% chocolate", s)
        let want = try foods.compute([(.init(fdcID: 170273, grams: 30),
                                       try foods.adjust(.init(why: "90% cacao", per100g: ["fat_g": 50, "carb_g": 32.1, "sugar_g": 14]),
                                                        for: 170273))])
        #expect(e.items[0].values == want[0].values)
        #expect(e.items[0].adjust?.factors["fat_g"] == 1.1729)
    }

    @Test func versionErrorsNameTheItem() async throws {
        let s = Script([
            [("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 100, "basis": "weighed", "version": {"why": "x", "per_100g": {"kcal": 5}}}], "summary": ""}"#)],
            [("nothing_to_log", #"{"reason": "gave up"}"#)],
        ])
        _ = try await run("grapes", s)
        #expect(try s.results(2) == [["error": .string("item 0 (grapes): version.per_100g can only give protein_g, fat_g, carb_g, "
                                                       + "sugar_g, fiber_g, sat_fat_g, sodium_mg (not kcal)")]])
    }

    @Test func modelToolErrorsReadLikeTheServers() async throws {
        let s = Script([
            [("get_food", #"{"fdc_id": 5}"#), ("lookup", #"{"food": "zzqx", "grams": 10}"#), ("search_foods", "{not json")],
            [("nothing_to_log", #"{"reason": "x"}"#)],
        ])
        _ = try await run("hm", s)
        #expect(try s.results(2) == [
            ["error": "Error executing tool get_food: no food with fdc_id 5"],
            ["error": "Error executing tool lookup: no food matches 'zzqx'; try fewer or different words"],
            ["error": "arguments are not valid JSON: {not json"],
        ])
    }

    @Test func nudgesOnceThenFails() async throws {
        let s = Script([[], [("nothing_to_log", #"{"reason": "a question, not food"}"#)]])
        let e = try await run("is chocolate healthy?", s)
        #expect(s.requests[1].messages.last == .user(logger.brain.finishHint))
        #expect(e.status == .nothing)
        #expect(e.reply == "a question, not food")

        let id = try log.addEntry(text: "hi")
        await #expect(throws: ToolLoop.Unfinished.self) {
            try await logger.run(id) { try Script([[], []]).send($0, $1) }
        }
    }

    @Test func dayOffsetMovesTheEntry() async throws {
        let s = Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 100, "basis": "weighed"}], "day_offset": -1, "summary": ""}"#)]])
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let e = try await run("yesterday I had 100 g of grapes", s, at: noon)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: noon)!
        #expect(e.day == LogDB.day(yesterday, .current))
        #expect(try log.totals(day: e.day)["kcal"] == 77.15)
    }

    @Test func duplicateItemsAreRejected() async throws {
        let item = #"{"fdc_id": 2263890, "said": "grapes", "grams": 100, "basis": "weighed"}"#
        let s = Script([
            [("log_food", #"{"items": [\#(item), \#(item)], "summary": ""}"#)],
            [("nothing_to_log", #"{"reason": "x"}"#)],
        ])
        _ = try await run("grapes", s)
        #expect(try s.results(2) == [["error": "item 1 repeats item 0; list each food once (use quantity or grams for more of it)"]])
    }

    @Test func deletedMidRunStopsQuietly() async throws {
        let s = Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 100, "basis": "weighed"}], "summary": ""}"#)]])
        let id = try log.addEntry(text: "grapes")
        s.beforeReply = { _ in try self.log.deleteEntry(id) }
        await #expect(throws: Logger.Gone.self) { try await logger.run(id) { try s.send($0, $1) } }
        #expect(try log.entry(id) == nil)
    }

    // MARK: - change requests

    @Test func changeRequestRelogsTheEntry() async throws {
        let first = Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 130, "basis": "weighed"}], "meal": "snack", "summary": "red"}"#)]])
        let e = try await run("130 g grapes", first)
        try log.requestEdit(e.id, "it was 200 grams")
        let s = Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 200, "basis": "weighed"}], "summary": "now 200 g"}"#)]])
        try await logger.run(e.id) { try s.send($0, $1) }
        let after = try #require(try log.entry(e.id))
        #expect(after.status == .done)
        #expect(after.pendingEdit == nil)
        #expect(after.edits == ["it was 200 grams"])
        #expect(after.items[0].grams == 200)
        #expect(after.meal == "snack")  // kept: the change didn't name a meal
        #expect(after.reply == "now 200 g")
        guard case .system(let system) = s.requests[0].messages[0], case .user(let parts) = s.requests[0].messages[1],
              case .text(let said) = parts[0] else { Issue.record("no prompt"); return }
        #expect(system == logger.brain.system + logger.brain.editSystem)
        #expect(said.contains("\nCurrently logged:\n- {\"fdc_id\": 2263890, \"said\": \"grapes\", \"grams\": 130, \"basis\": \"weighed\"} = Grapes, red, seedless, raw: 100 kcal, P 1.2 F 0.2 C 26.3 g"))
        #expect(said.hasSuffix("\n\nChange requested: it was 200 grams"))
    }

    /// Redo starts over with the model but keeps the user's changes, and tells
    /// the model to apply them.
    @Test func redoKeepsTheChanges() async throws {
        let first = Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 130, "basis": "weighed"}], "summary": "red"}"#)]])
        let e = try await run("130 g grapes", first)
        try log.requestEdit(e.id, "it was 200 grams")
        try await logger.run(e.id) { try Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 200, "basis": "weighed"}], "summary": "200 g"}"#)]]).send($0, $1) }

        try log.redo(e.id)
        let queued = try #require(try log.entry(e.id))
        #expect(queued.status == .queued && queued.items.isEmpty)
        #expect(queued.edits == ["it was 200 grams"])

        let s = Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 200, "basis": "weighed"}], "summary": "200 g"}"#)]])
        try await logger.run(e.id) { try s.send($0, $1) }
        let after = try #require(try log.entry(e.id))
        #expect(after.status == .done)
        #expect(after.edits == ["it was 200 grams"])
        #expect(after.items[0].grams == 200)
        guard case .system(let system) = s.requests[0].messages[0], case .user(let parts) = s.requests[0].messages[1],
              case .text(let said) = parts[0] else { Issue.record("no prompt"); return }
        #expect(system == logger.brain.system)  // a fresh log, not an edit
        #expect(said.hasSuffix("Typed: 130 g grapes\n\nThe user has corrected this entry since; log it with these "
                               + "changes applied: \u{201C}it was 200 grams\u{201D}"))
    }

    @Test func changeThatChangesNothingKeepsTheEntry() async throws {
        let e = try await run("130 g grapes", Script([[("log_food", #"{"items": [{"fdc_id": 2263890, "said": "grapes", "grams": 130, "basis": "weighed"}], "summary": ""}"#)]]))
        try log.requestEdit(e.id, "it was delicious")
        try await logger.run(e.id) { try Script([[("nothing_to_log", #"{"reason": "not a change to the food"}"#)]]).send($0, $1) }
        let after = try #require(try log.entry(e.id))
        #expect(after.status == .done)
        #expect(after.items.count == 1)
        #expect(after.error == "Nothing changed for \u{201C}it was delicious\u{201D}: not a change to the food")
    }

    // MARK: - voice and photos

    @Test func voiceIsTranscribedFirst() async throws {
        let rec = try Media.save(Data("RIFF".utf8), ext: "wav")
        let id = try log.addEntry(audio: rec)
        logger.transcribe = { _ in .init(text: "eighty one grams of asian pear") }
        let s = Script([[("nothing_to_log", #"{"reason": "x"}"#)]])
        // process() picks a model by the route; run the same steps with the script instead
        try await transcribeThenRun(id, s)
        let e = try #require(try log.entry(id))
        #expect(e.transcript == "eighty one grams of asian pear")
        guard case .user(let parts) = s.requests[0].messages[1], case .text(let said) = parts[0] else { return }
        #expect(said.hasSuffix("\nVoice transcript: eighty one grams of asian pear"))
        try log.deleteEntry(id)
        #expect(!FileManager.default.fileExists(atPath: try Media.url(rec).path))
    }

    private func transcribeThenRun(_ id: Int64, _ s: Script) async throws {
        let e = try #require(try log.entry(id))
        let heard = try await logger.transcribe(try Media.url(e.audio!))
        try log.update(id, Logger.fields(heard))
        try await logger.run(id) { try s.send($0, $1) }
    }

    @Test func otherReadingsGoToTheModel() async throws {
        let id = try log.addEntry(audio: try Media.save(Data("RIFF".utf8), ext: "wav"))
        logger.transcribe = { _ in .init(text: "one pair", alternatives: ["one pear", "won pair"]) }
        let s = Script([[("nothing_to_log", #"{"reason": "x"}"#)]])
        try await transcribeThenRun(id, s)
        let e = try #require(try log.entry(id))
        #expect(e.transcript == "one pair")
        #expect(e.alternatives == ["one pear", "won pair"])
        guard case .user(let parts) = s.requests[0].messages[1], case .text(let said) = parts[0] else { return }
        #expect(said.hasSuffix("\nVoice transcript: one pair\nThe recognizer's other readings of it: \u{201C}one pear\u{201D}, \u{201C}won pair\u{201D}"))
        try log.deleteEntry(id)
    }

    @Test func photoGoesToTheModel() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let id = try log.addEntry(photo: try Media.save(jpeg, ext: "jpg"))
        let s = Script([[("nothing_to_log", #"{"reason": "x"}"#)]])
        try await logger.run(id) { try s.send($0, $1) }
        guard case .user(let parts) = s.requests[0].messages[1], case .text(let said) = parts[0] else { return }
        #expect(said.hasSuffix("\nPhoto attached: the food about to be eaten."))
        #expect(parts.last == .jpeg(jpeg))
        try log.deleteEntry(id)
    }

    // MARK: - recipes and labels

    @Test func recipeDraft() async throws {
        let s = Script([
            [("search_foods", #"{"query": "egg white"}"#)],
            [("recipe_ingredients", #"{"items": [{"fdc_id": 172183, "said": "2 egg whites", "grams": 66}, {"fdc_id": 2263890, "said": "a cup of grapes", "grams": 151, "note": "red"}], "left_out": [{"said": "salt", "reason": "to taste"}]}"#)],
        ])
        let d = try await logger.recipe(name: "Egg and grapes", text: "2 egg whites, a cup of grapes, salt") { try s.send($0, $1) }
        #expect(d.ingredients.map(\.fdcID) == [172183, 2263890])
        #expect(d.ingredients[1].note == "red")
        #expect(d.leftOut.map(\.reason) == ["to taste"])
        #expect(s.requests[0].tools.map(\.name) == ["search_foods", "lookup", "get_food", "recipe_ingredients", "not_a_recipe"])
        #expect(s.requests[0].messages[0] == .system(logger.brain.recipeSystem))
        var i = d.ingredients[1]
        i.grams = i.grams0 * 2
        #expect(i.value("kcal") == 2 * (i.values0["kcal"]! ?? 0))
        await #expect(throws: Logger.Failure.self) {
            try await logger.recipe(name: "x", text: "hello") { try Script([[("not_a_recipe", #"{"reason": "a greeting"}"#)]]).send($0, $1) }
        }
    }

    @Test func labelReading() async throws {
        final class Fixed {
            var text: String
            var request: LLM.Request?
            init(_ t: String) { text = t }
        }
        let f = Fixed(#"{"readable": true, "name": "Lox", "serving_label": "2 oz (56g)", "serving_g": 56, "kcal": 100, "protein_g": 12, "fat_g": 5, "carb_g": 0, "fiber_g": null, "sugar_g": null, "sat_fat_g": 1, "sodium_mg": 1050, "cholesterol_mg": null}"#)
        let l = try await logger.readLabel(Data([0xFF])) { req, _ in
            f.request = req
            return LLM.Reply(text: f.text, calls: [], native: nil, usage: nil)
        }
        #expect(l.name == "Lox")
        #expect(l.servingG == 56)
        #expect(l.perServing["sodium_mg"] == 1050)
        #expect(l.perServing["fiber_g"] == .some(nil))
        #expect(f.request?.jsonSchema?.name == "label")
        f.text = #"{"readable": false, "name": null}"#
        await #expect(throws: Logger.Failure.self) {
            try await logger.readLabel(Data([0xFF])) { _, _ in LLM.Reply(text: f.text, calls: [], native: nil, usage: nil) }
        }
    }

    @Test func recipePhotoReading() async throws {
        var sent: LLM.Request?
        var text = #"{"readable": true, "name": "Chili", "servings": 4, "ingredients": ["2 tbsp olive oil", "  ", " 1 lb ground chicken "]}"#
        let r = try await logger.readRecipePhoto(Data([0xFF])) { req, _ in
            sent = req
            return LLM.Reply(text: text, calls: [], native: nil, usage: nil)
        }
        #expect(r == .init(name: "Chili", servings: 4, text: "2 tbsp olive oil\n1 lb ground chicken"))
        #expect(sent?.jsonSchema?.name == "recipe")
        for bad in [#"{"readable": false, "name": null, "servings": null, "ingredients": []}"#,
                    #"{"readable": true, "name": "x", "servings": null, "ingredients": []}"#, "not json"] {
            text = bad
            await #expect(throws: Logger.Failure.self) {
                try await logger.readRecipePhoto(Data([0xFF])) { _, _ in LLM.Reply(text: text, calls: [], native: nil, usage: nil) }
            }
        }
    }

    // MARK: - edits by hand

    @Test func itemEditsByHand() async throws {
        let s = Script([[("log_food", #"""
            {"items": [{"fdc_id": 170273, "said": "chocolate", "grams": 30, "basis": "estimated", "note": "a few squares",
              "version": {"why": "90%", "per_100g": {"fat_g": 50}}}], "summary": ""}
            """#)]])
        let e = try await run("some 90% chocolate", s)
        let item = e.items[0]
        try logger.editItem(item, grams: 40)
        var now = try #require(try log.entry(e.id)).items[0]
        #expect(now.grams == 40)
        #expect(now.basis == "weighed")
        #expect(now.adjust == item.adjust)  // same food: the version stays
        try logger.editItem(now, grams: 40, fdcID: 170272)
        now = try #require(try log.entry(e.id)).items[0]
        #expect(now.fdcID == 170272)
        #expect(now.adjust == nil && now.note == nil)  // another food starts from its own numbers
        try logger.addItem(to: e.id, fdcID: 2263890, grams: 100)
        #expect(try #require(try log.entry(e.id)).items.map(\.fdcID) == [170272, 2263890])
        try log.redo(e.id)
        let redone = try #require(try log.entry(e.id))
        #expect(redone.items.isEmpty && redone.status == .queued && redone.reply == nil)
    }

    /// A real recording through on-device speech to text and the real model.
    /// Needs a device with a speech model (an iPhone, or the Mac running the
    /// app as "Designed for iPhone"), not the Simulator:
    /// The live tests' model: TEST_RUNNER_BITELOG_MODEL (default qwen38) on the
    /// TEST_RUNNER_BITELOG_LIVE server, with its family's sampling, thinking off.
    static func liveProfile() -> Profile {
        let env = ProcessInfo.processInfo.environment
        let model = env["BITELOG_MODEL"] ?? "qwen38"
        let sampling: JSON = model.lowercased().hasPrefix("gemma")
            ? ["temperature": 1.0, "top_p": 0.95, "top_k": 64]   // Google's
            : ["temperature": 0.6, "top_p": 0.95, "top_k": 20]   // Qwen's for precise work
        return Profile(name: "Home", kind: .openAI, baseURL: env["BITELOG_LIVE"]!, model: model, vision: true,
                       extra: sampling.merging(["chat_template_kwargs": ["enable_thinking": false]]))
    }

    /// The log shows what the model took the food to be, not the misheard words.
    /// TEST_RUNNER_BITELOG_LIVE=http://<server>:<port>/v1 xcodebuild … test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil), .timeLimit(.minutes(10)))
    func liveMisheardNamesAreFixed() async throws {
        let id = try log.addEntry()
        try log.update(id, ["transcript": "Sixty grams of smoked salmon locks and a bowl of great yogurt."])
        let p = Self.liveProfile()
        try await logger.run(id) { req, onWait in try await logger.client.send(req, via: p, onWait: onWait) }
        let names = try #require(try log.entry(id)).items.compactMap { $0.said?.lowercased() }
        #expect(names.contains { $0.contains("lox") }, "\(names)")
        #expect(names.contains { $0.contains("greek") }, "\(names)")
        #expect(!names.contains { $0.contains("locks") || $0.contains("great") }, "\(names)")
    }

    /// Transcripts spelled by sound: a homophone of a food stands for that food.
    /// None of these words appear in the prompt, so passing means the model
    /// applied the rule, not an example.
    nonisolated static let soundAlikes: [(heard: String, food: String, wrong: String)] = [
        ("One pair.", "pear", "pair"),
        ("A bowl of serial with milk.", "cereal", "serial"),
        ("A beat salad.", "beet", "beat"),
        ("A cup of leak and potato soup.", "leek", "leak"),
        ("A bowl of chilly with beans.", "chili", "chilly"),
        ("About two hundred grams of steamed muscles.", "mussel", "muscle"),
        ("Chicken carry with white rice.", "curry", "carry"),
        ("A handful of dried currents.", "currant", "current"),
        ("A filet of soul, baked.", "sole", "soul"),
        ("A scoop of way protein in water.", "whey", "way"),
        ("A mug of tee with honey.", "tea", "tee"),
        ("Six ounces of grilled stake.", "steak", "stake"),
        ("Two slices of wry bread.", "rye", "wry"),
        ("A bowl of oat meal with a teaspoon of cinnamon and a hand full of rays ins.", "raisin", "rays"),
    ]

    /// TEST_RUNNER_BITELOG_LIVE=http://<server>:<port>/v1 xcodebuild … test
    /// The one sound-alike the rule alone misses ("pair" is also an amount
    /// word), with the recognizer's other reading supplied.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil), .timeLimit(.minutes(10)))
    func liveOtherReadingSettlesIt() async throws {
        let id = try log.addEntry()
        try log.update(id, Logger.fields(.init(text: "One pair.", alternatives: ["One pear."])))
        let p = Self.liveProfile()
        try await logger.run(id) { req, onWait in try await logger.client.send(req, via: p, onWait: onWait) }
        let e = try #require(try log.entry(id))
        let names = e.items.compactMap { $0.said?.lowercased() }
        #expect(names.contains { $0.contains("pear") }, "\(names) \(e.reply ?? e.error ?? "")")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil), .timeLimit(.minutes(10)),
          arguments: soundAlikes)
    func liveSoundAlikes(_ c: (heard: String, food: String, wrong: String)) async throws {
        let id = try log.addEntry()
        try log.update(id, ["transcript": c.heard])
        let p = Self.liveProfile()
        try await logger.run(id) { req, onWait in try await logger.client.send(req, via: p, onWait: onWait) }
        let e = try #require(try log.entry(id))
        let names = e.items.compactMap { $0.said?.lowercased() }
        #expect(names.contains { $0.contains(c.food) }, "\(c.heard) -> \(names) \(e.reply ?? e.error ?? "")")
        #expect(!names.contains { $0.contains(c.wrong) }, "\(c.heard) -> \(names)")
    }

    /// On a phone with the recordings in the test bundle (see VoiceTests):
    ///   TEST_RUNNER_BITELOG_LIVE=http://<server>:<port>/v1 xcodebuild … -destination 'platform=iOS,id=<phone>' test
    @Test(.enabled(if: VoiceTests.recordings != nil
                   && ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil), .timeLimit(.minutes(10)))
    func liveVoiceEntry() async throws {
        let wav = try #require(VoiceTests.recordings).appendingPathComponent("media/3e28925ed92044fc83fe0dd343753f3d.wav")
        let id = try log.addEntry(audio: try Media.save(Data(contentsOf: wav), ext: "wav"))  // "Eighty one grams of Asian pear."
        let heard = try await logger.transcribe(try Media.url(#require(try log.entry(id)?.audio)))
        let words = heard.text
        try log.update(id, Logger.fields(heard))
        let p = Self.liveProfile()
        try await logger.run(id) { req, onWait in try await logger.client.send(req, via: p, onWait: onWait) }
        let e = try #require(try log.entry(id))
        #expect(words.lowercased().contains("pear"), "heard: \(words)")
        #expect(e.status == .done, "\(e.error ?? "")")
        #expect(e.items.first?.grams == 81, "\(e.items.map { "\($0.description) \($0.grams) g" })")
        try log.deleteEntry(id)
    }

    /// The whole thing against the real gateway, only when asked:
    /// TEST_RUNNER_BITELOG_LIVE=http://<server>:<port>/v1 xcodebuild … test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil), .timeLimit(.minutes(10)))
    func liveEntry() async throws {
        let p = Self.liveProfile()
        let id = try log.addEntry(text: "130 grams of red seedless grapes and two scrambled eggs")
        try await logger.run(id) { req, onWait in try await logger.client.send(req, via: p, onWait: onWait) }
        let e = try #require(try log.entry(id))
        #expect(e.status == .done, "\(e.error ?? "")")
        #expect(e.items.count == 2)
        #expect((180...330).contains(e.kcal), "\(e.items.map { "\($0.description) \($0.grams) g" })")
    }

    /// A recipe page drawn here, read by the real model through the phone's own
    /// request path (the strict schema with anyOf nullables).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil), .timeLimit(.minutes(5)))
    func liveRecipePhoto() async throws {
        let p = Self.liveProfile()
        let page = """
            Weeknight Chicken Chili
            Serves 4-6

            INGREDIENTS
            2 tbsp olive oil
            1 large onion, diced
            1 lb ground chicken
            For the topping:
            1/2 cup shredded cheddar

            METHOD
            1. Heat the oil and soften the onion.
            2. Brown the chicken. Add 2 cups of water and simmer 30 minutes.
            3. Top with the cheddar.
            """
        let size = CGSize(width: 1000, height: 1100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            (page as NSString).draw(in: CGRect(x: 60, y: 60, width: 880, height: 1000),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 34)])
        }.jpegData(compressionQuality: 0.85)!
        let r = try await logger.readRecipePhoto(jpeg) { req, w in try await logger.client.send(req, via: p, onWait: w) }
        #expect(r.name == "Weeknight Chicken Chili")
        #expect(r.servings == 4)
        let lines = r.text.split(separator: "\n").map { $0.lowercased() }
        #expect(lines.count == 5, "\(lines)")
        #expect(lines.contains { $0.contains("water") }, "the water from the method: \(lines)")
        #expect(!lines.contains { $0.contains("topping") }, "a heading: \(lines)")
    }
}
