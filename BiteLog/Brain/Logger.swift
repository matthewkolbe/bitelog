import Foundation
import Observation

/// Turns entries into logged items: speech to text, a model picked by the
/// route, the tool loop, and what `log_food` logs; applies change requests;
/// breaks recipes down and reads package labels. A port of brain.py's Logger
/// and app.py's item edits.
@Observable
final class Logger {
    typealias Send = (LLM.Request, (Bool) -> Void) async throws -> LLM.Reply

    let foods: FoodDB
    let log: LogDB
    let brain: Brain
    let client: LLMClient
    let profiles: ProfileStore
    /// The setting that sends the user's recent foods with each entry.
    nonisolated static let recentFoodsKey = "recentFoods"
    /// Whether it's on; tests swap it.
    @ObservationIgnored var recentFoodsOn: () -> Bool = { UserDefaults.standard.bool(forKey: Logger.recentFoodsKey) }
    /// Speech to text; tests swap it.
    @ObservationIgnored var transcribe: (URL) async throws -> Transcriber.Transcript = Transcriber.transcribe
    private(set) var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// The entry was deleted while it was being processed.
    struct Gone: Error {}

    /// The log columns a transcript fills.
    static func fields(_ t: Transcriber.Transcript) -> [String: String?] {
        ["transcript": t.text,
         "alternatives": t.alternatives.isEmpty ? nil
             : String(decoding: try! JSONEncoder().encode(t.alternatives), as: UTF8.self)]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(foods: FoodDB, log: LogDB, brain: Brain, client: LLMClient, profiles: ProfileStore) {
        self.foods = foods
        self.log = log
        self.brain = brain
        self.client = client
        self.profiles = profiles
    }

    // MARK: - the queue

    /// Processes unfinished entries, oldest first, one at a time. Calling it
    /// while it runs makes it look again when it's done.
    func kick() {
        guard !running else { again = true; return }
        running = true
        worker = Task {
            defer { running = false }
            repeat {
                again = false
                for id in (try? log.unfinished()) ?? [] {
                    if await !process(id) { break }
                }
            } while again
        }
    }

    /// Returns when the queue has nothing left it can process.
    func settled() async {
        while running, let w = worker { await w.value }
    }

    /// One entry. False when no model is available (the entry stays queued and
    /// the rest wait too).
    @discardableResult
    func process(_ id: Int64) async -> Bool {
        var request: String?
        do {
            var e = try entry(id)
            request = e.pendingEdit
            if let a = e.audio, e.transcript == nil {
                try log.update(id, status: .transcribing, ["error": nil])
                let heard = try await transcribe(Media.url(a))
                _ = try entry(id)
                try log.update(id, Self.fields(heard))
                e.transcript = heard.text
                e.alternatives = heard.alternatives
            }
            if (e.transcript ?? "").isEmpty && (e.text ?? "").isEmpty && e.photo == nil {
                try log.update(id, status: .nothing, ["reply": "Heard nothing."])
                return true
            }
            let profile: Profile
            if let want = e.useProfile {
                // a redo with a chosen model: that one or none
                guard let p = profiles.profiles.first(where: { $0.id == want }) else {
                    try log.update(id, status: .error, ["error": "The model chosen for this redo was removed.", "use_profile": nil])
                    return true
                }
                guard p.enabled else {
                    try log.update(id, status: .error, ["error": "\(p.name) is switched off in Settings.", "use_profile": nil])
                    return true
                }
                do {
                    profile = try await client.route([p], needsVision: e.photo != nil)
                } catch {
                    // waits for that model; the other entries don't wait with it
                    try log.update(id, status: .queued, ["error": "Waiting for \(p.name): \(error)"])
                    return true
                }
            } else {
                do {
                    profile = try await client.route(profiles.profiles, needsVision: e.photo != nil)
                } catch {
                    try log.update(id, status: .queued, ["error": "Waiting for a model: \(error)"])
                    return false
                }
            }
            try log.update(id, status: .thinking, ["model": "\(profile.name) (\(profile.model))", "error": nil,
                                                   "use_profile": nil])
            try await run(id) { req, onWait in try await self.client.send(req, via: profile, onWait: onWait) }
        } catch is Gone {
        } catch {
            if let request {
                // a change that can't be applied leaves the entry as it was, with the reason on it
                try? log.update(id, status: .done, ["pending_edit": nil,
                                                    "error": "Couldn't apply \u{201C}\(request)\u{201D}: \(error)"])
            } else {
                try? log.update(id, status: .error, ["error": String(describing: error)])
            }
        }
        return true
    }

    /// The tool loop for one entry (or its pending change) with a chosen model.
    func run(_ id: Int64, send: Send) async throws {
        let e = try entry(id)
        let tz = TimeZone(identifier: e.tz) ?? .current
        var lines = said(e, tz)
        var system = brain.system
        let edit = e.pendingEdit
        if let edit {
            system += brain.editSystem
            lines += ["", "Currently logged:"]
            for it in e.items {
                var amount: [(String, JSON)] = [("fdc_id", .number(Double(it.fdcID)))]
                if let s = it.said { amount.append(("said", .string(s))) }
                amount += [("grams", .number(pyRound(it.grams, 1))), ("basis", .string(it.basis))]
                if let n = it.note { amount.append(("note", .string(n))) }
                if let a = it.adjust {
                    amount.append(("version", .object(["why": .string(a.why), "per_100g": .object(a.per100g.mapValues(JSON.number))])))
                }
                func v(_ k: String) -> Double { (it.values[k] ?? nil) ?? 0 }
                lines.append("- \(try pyDumps(amount)) = \(it.description): \(String(format: "%.0f", v("kcal"))) kcal, "
                             + "P \(String(format: "%.1f", v("protein_g"))) F \(String(format: "%.1f", v("fat_g"))) "
                             + "C \(String(format: "%.1f", v("carb_g"))) g")
            }
            if !e.edits.isEmpty {
                lines.append("Changes already applied: " + e.edits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: "; "))
            }
            lines += try householdFoods() + ["", "Change requested: \(edit)"]
        } else {
            // a redone entry keeps the changes the user asked for (brain.py's _changes)
            if !e.edits.isEmpty {
                lines += ["", "The user has corrected this entry since; log it with these changes applied: "
                          + e.edits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: "; ")]
            }
            lines += try householdFoods()
            if recentFoodsOn() { lines += try recentFoods(e) }
        }
        var content: [LLM.Part] = [.text(lines.joined(separator: "\n"))]
        if let p = e.photo { content.append(.jpeg(try Data(contentsOf: Media.url(p)))) }
        let onWait: (Bool) -> Void = { [log] waiting in try? log.update(id, status: waiting ? .waiting : .thinking) }
        try await ToolLoop.run([.system(system), .user(content)], tools: brain.tools,
                               maxRounds: brain.maxRounds, finishHint: brain.finishHint,
                               send: { try await send($0, onWait) },
                               handle: { name, args in try self.tool(name, args, entry: e, tz: tz, edit: edit) })
    }

    private func entry(_ id: Int64) throws -> LogDB.Entry {
        guard let e = try log.entry(id) else { throw Gone() }
        return e
    }

    /// brain.py's _said: when, and what was said, typed or photographed.
    private func said(_ e: LogDB.Entry, _ tz: TimeZone) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        var lines = ["Entry time: \(f.string(from: e.createdAt)) (user's local time)."]
        if let t = e.transcript, !t.isEmpty { lines.append("Voice transcript: \(t)") }
        if !e.alternatives.isEmpty {
            lines.append("The recognizer's other readings of it: " + e.alternatives.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
        }
        if let t = e.text, !t.isEmpty { lines.append("Typed: \(t)") }
        if e.photo != nil {
            lines.append((e.transcript ?? "").isEmpty && (e.text ?? "").isEmpty
                         ? "Photo attached: the food about to be eaten." : "Photo attached.")
        }
        return lines
    }

    /// brain.py's recent_food_lines: the foods logged in the days before this
    /// entry, latest first, one line per said name and entry.
    func recentFoods(_ e: LogDB.Entry) throws -> [String] {
        let since = e.createdAt.addingTimeInterval(-Double(brain.recentDays) * 86_400)
        var seen = Set<String>(), out: [String] = []
        for it in try log.recentItems(excluding: e.id, since: since, before: e.createdAt) {
            let said = it.said.flatMap { $0.isEmpty ? nil : $0 } ?? it.description
            guard seen.insert("\(said.lowercased())\u{0}\(it.fdcID)").inserted else { continue }
            var line = "- \(said) = \(it.description) (fdc_id \(it.fdcID))"
            if let a = it.adjust {
                line += "; their version per 100 g: "
                    + (try pyDumps(a.per100g.sorted { $0.key < $1.key }.map { ($0.key, JSON.number($0.value)) }))
            }
            out.append(line)
            if out.count == brain.recentMax { break }
        }
        return out.isEmpty ? [] : ["", brain.recentFoods] + out
    }

    /// The custom (package-label) foods, listed in every request: a search only
    /// finds one when its words hit the name or an alias, and the model searches
    /// in USDA phrasing while speech to text mangles product names.
    private func householdFoods() throws -> [String] {
        let foods = try foods.customFoods()
        guard !foods.isEmpty else { return [] }
        return ["", "Household foods: products entered from their package labels, and recipes they cook. "
                    + "When the user means one of these — by its name, another name, the store or brand, a "
                    + "homemade dish of that name, or a mishearing of them — log it with its fdc_id, not a "
                    + "USDA entry:"]
            + foods.map { f in
                var also = f.aliases.isEmpty ? "" : " (also called: \(f.aliases))"
                if f.kind == "recipe" { also = " [recipe]\(also)" }
                let g = FoodDB.g(f.servingG)
                return "- fdc_id \(f.fdcID): \(f.description)\(also); portion '1 serving' = "
                    + "\(f.servingLabel ?? "\(g) g") = \(g) g"
            }
    }

    // MARK: - tools

    private func tool(_ name: String, _ args: JSON, entry e: LogDB.Entry, tz: TimeZone,
                      edit: String?) throws -> ToolLoop.Outcome {
        switch name {
        case "search_foods", "lookup", "get_food":
            return .result(modelTool(name, args))
        case "nothing_to_log":
            _ = try entry(e.id)
            let reason = args["reason"]?.string
            if let edit {
                try log.update(e.id, status: .done, ["pending_edit": nil,
                    "error": "Nothing changed for \u{201C}\(edit)\u{201D}: \(reason ?? "no change to the food")"])
            } else {
                try log.update(e.id, status: .nothing, ["reply": reason ?? "Nothing to log."])
            }
            return .done
        case "log_food":
            return try logFood(args, entry: e, tz: tz, edit: edit)
        default:
            return .result(["error": .string("unknown tool \(name)")])
        }
    }

    /// search_foods / lookup / get_food, answering as the nutrition server does
    /// (its MCP errors read "Error executing tool <name>: …").
    func modelTool(_ name: String, _ a: JSON) -> JSON {
        do {
            return try modelToolResult(name, a)
        } catch {
            return ["error": .string("Error executing tool \(name): \(error)")]
        }
    }

    private func modelToolResult(_ name: String, _ a: JSON) throws -> JSON {
        func bad(_ m: String) -> FoodDB.Failure { .invalid(m) }
        switch name {
        case "search_foods":
            guard let q = a["query"]?.string else { throw bad("query is required: food name words") }
            let limit = a["limit"]?.int ?? 15
            guard (1...50).contains(limit) else { throw bad("limit must be 1 to 50") }
            return .array(try foods.search(q, source: a["source"]?.string, limit: limit).map(Self.json))
        case "lookup":
            guard let food = a["food"]?.string else { throw bad("food is required: a food name") }
            guard let grams = a["grams"]?.double, grams > 0 else { throw bad("grams is required, more than 0") }
            let n = a["alternatives"]?.int ?? 8
            guard (0...20).contains(n) else { throw bad("alternatives must be 0 to 20") }
            let r = try foods.lookup(food, grams: grams, alternatives: n)
            return ["match": (["fdc_id": .number(Double(r.match.fdcID)), "description": .string(r.match.description),
                               "source": .string(r.source), "grams": .number(grams)] as JSON).merging(Self.json(r.match.values)),
                    "alternatives": .array(r.alternatives.map {
                        ["fdc_id": .number(Double($0.fdcID)), "description": .string($0.description),
                         "source": .string($0.source), "kcal": .number($0.kcal)]
                    })]
        case "get_food":
            guard let id = a["fdc_id"]?.int else { throw bad("fdc_id is required: an integer") }
            let f = try foods.food(id)
            var out: JSON = ["fdc_id": .number(Double(id)), "description": .string(f.description),
                             "source": .string(f.source), "category": f.category.map(JSON.string) ?? .null,
                             "per_100g": Self.json(f.per100g),
                             "portions": .array(f.portions.map { ["label": .string($0.label), "gram_weight": .number($0.grams)] })]
            if case .bool(true)? = a["all_nutrients"], id > 0 {
                out = out.merging(["all_nutrients_per_100g": .array(try foods.allNutrients(id).map {
                    ["name": .string($0.name), "amount": .number($0.amount), "unit": .string($0.unit)]
                })])
            }
            return out
        default:
            throw bad("unknown tool \(name)")
        }
    }

    /// Items the model sent (log_food, recipe_ingredients), checked as brain.py
    /// checks them. A string is the error for the model.
    private struct Checked {
        var amount: FoodDB.Amount
        var adjust: Nutrition.Adjust?
        var it: JSON
    }

    private func check(_ items: [JSON], basis needed: Bool) -> Result<[Checked], Failure> {
        var out: [Checked] = []
        for (i, it) in items.enumerated() {
            let said = it["said"]?.string ?? "None"
            let grams = it["grams"]?.double, portion = it["portion"]?.string
            let amount = it["amount"]?.double, unit = it["unit"]?.string
            if let m = FoodDB.amountError(grams: grams, portion: portion, amount: amount, unit: unit) {
                return .failure(.init(description: "item \(i) (\(said)): \(m)"))
            }
            if needed, !["weighed", "portion", "estimated"].contains(it["basis"]?.string ?? "") {
                return .failure(.init(description: "item \(i) (\(said)): basis must be weighed, portion or estimated"))
            }
            guard let fdcID = it["fdc_id"]?.int else {
                return .failure(.init(description: "item \(i) (\(said)): fdc_id is required"))
            }
            var adjust: Nutrition.Adjust?
            if needed, let v = it["version"], v != .null {
                do {
                    adjust = try version(v, fdcID: fdcID)
                } catch {
                    return .failure(.init(description: "item \(i) (\(said)): \(error)"))
                }
            }
            out.append(Checked(amount: .init(fdcID: fdcID, grams: grams, portion: portion,
                                             quantity: it["quantity"]?.double ?? 1, amount: amount, unit: unit),
                               adjust: adjust, it: it))
        }
        return .success(out)
    }

    /// FoodDB.compute, failing with the nutrition server's message.
    private func compute(_ items: [Checked]) -> Result<[FoodDB.Scaled], Failure> {
        do {
            return .success(try foods.compute(items.map { ($0.amount, $0.adjust) }))
        } catch {
            return .failure(.init(description: "Error executing tool nutrition: \(error)"))
        }
    }

    /// brain.py's _no_items: why a log_food call has nothing to log. The model
    /// sometimes sends one item at the top level instead of inside items, and
    /// must be told so, or it retries the same shape until the round limit.
    static func noItems(_ args: JSON) -> String {
        args["fdc_id"] != nil || args["said"] != nil
            ? "items is missing: you sent one item at the top level; send {\"items\": [that item, ...], ...}"
            : "items is empty"
    }

    /// brain.py's _log: checks every item, computes the numbers, stores them.
    private func logFood(_ args: JSON, entry e: LogDB.Entry, tz: TimeZone, edit: String?) throws -> ToolLoop.Outcome {
        func error(_ m: String) -> ToolLoop.Outcome { .result(["error": .string(m)]) }
        let items = args["items"]?.array ?? []
        guard !items.isEmpty else { return error(Self.noItems(args) + "; use nothing_to_log if nothing was eaten") }
        let checked: [Checked]
        switch check(items, basis: true) {
        case .failure(let f): return error(f.description)
        case .success(let c): checked = c
        }
        let keys = ["fdc_id", "said", "grams", "portion", "quantity", "amount", "unit"]
        for i in items.indices {
            for j in 0..<i where keys.allSatisfy({ items[j][$0] == items[i][$0] }) {
                return error("item \(i) repeats item \(j); list each food once (use quantity or grams for more of it)")
            }
        }
        let offset = args["day_offset"]?.int ?? 0
        if offset > 0 { return error("day_offset cannot be in the future") }
        let numbers: [FoodDB.Scaled]
        switch compute(checked) {
        case .failure(let f): return error(f.description)
        case .success(let n): numbers = n
        }
        let current = try entry(e.id)
        try log.replaceItems(e.id, zip(checked, numbers).map { c, n in
            LogDB.NewItem(fdcID: c.amount.fdcID, description: n.description, said: c.it["said"]?.string, grams: n.grams,
                          basis: c.it["basis"]?.string ?? "", note: c.it["note"]?.string, adjust: c.adjust, values: n.values)
        })
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let day = LogDB.day(cal.date(byAdding: .day, value: offset, to: e.createdAt)!, tz)
        if let edit {
            let edits = String(decoding: try JSONEncoder().encode(current.edits + [edit]), as: UTF8.self)
            try log.update(e.id, status: .done, ["reply": args["summary"]?.string, "error": nil, "pending_edit": nil,
                                                 "edits": edits, "meal": args["meal"]?.string ?? current.meal,
                                                 "day": offset != 0 ? day : current.day])
        } else {
            try log.update(e.id, status: .done, ["reply": args["summary"]?.string, "meal": args["meal"]?.string,
                                                 "error": nil, "day": day])
        }
        return .done
    }

    /// The model's version -> the item's adjust, with version_adjust's checks in its order.
    private func version(_ v: JSON, fdcID: Int) throws -> Nutrition.Adjust {
        guard let why = v["why"]?.string, !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Nutrition.Invalid("version needs why: the entry's numbers per 100 g and the user's version worked out")
        }
        guard let per = v["per_100g"]?.object, !per.isEmpty else {
            throw Nutrition.Invalid("version.per_100g is empty; leave version out when the entry matches")
        }
        let bad = Set(per.keys).subtracting(Nutrition.adjustable)
        guard bad.isEmpty else {
            throw Nutrition.Invalid("version.per_100g can only give \(Nutrition.adjustable.joined(separator: ", ")) "
                                    + "(not \(bad.sorted().joined(separator: ", ")))")
        }
        let food: FoodDB.Food
        do {
            food = try foods.food(fdcID)
        } catch {
            throw Nutrition.Invalid("Error executing tool get_food: \(error)")
        }
        var numbers: [String: Double] = [:]
        for (k, x) in per {
            guard let n = x.double else { throw Nutrition.Invalid("version.per_100g.\(k) must be a number of 0 or more") }
            numbers[k] = n
        }
        return try Nutrition.adjust(.init(why: why, per100g: numbers), on: food)
    }

    // MARK: - recipes

    /// A recipe's breakdown, saved as it comes back.
    struct RecipeDraft: Equatable {
        struct Ingredient: Equatable {
            var fdcID: Int
            var said: String?
            var note: String?
            var description: String
            /// The breakdown's grams and numbers; edits scale from these.
            let grams0: Double
            let values0: FoodDB.Nutrients
            var grams: Double

            func value(_ k: String) -> Double { ((values0[k] ?? nil) ?? 0) * grams / grams0 }
        }
        var ingredients: [Ingredient]
        var leftOut: [(said: String, reason: String)]

        static func == (a: RecipeDraft, b: RecipeDraft) -> Bool {
            a.ingredients == b.ingredients && a.leftOut.map(\.said) == b.leftOut.map(\.said)
                && a.leftOut.map(\.reason) == b.leftOut.map(\.reason)
        }
    }

    /// brain.py's Logger.recipe, with a model from the route.
    func recipe(name: String, text: String) async throws -> RecipeDraft {
        let p = try await client.route(profiles.profiles, needsVision: false)
        return try await recipe(name: name, text: text) { req, w in try await self.client.send(req, via: p, onWait: w) }
    }

    func recipe(name: String, text: String, send: Send) async throws -> RecipeDraft {
        let lines = ["Recipe: \(name)", text] + (try householdFoods())
        var draft: RecipeDraft?
        try await ToolLoop.run([.system(brain.recipeSystem), .user(lines.joined(separator: "\n"))], tools: brain.recipeTools,
                               maxRounds: brain.recipeRounds, finishHint: brain.recipeFinishHint,
                               send: { try await send($0, { _ in }) }) { tool, args in
            switch tool {
            case "search_foods", "lookup", "get_food":
                return .result(self.modelTool(tool, args))
            case "not_a_recipe":
                throw Failure(description: args["reason"]?.string ?? "That doesn't read as a recipe.")
            case "recipe_ingredients":
                let items = args["items"]?.array ?? []
                if items.isEmpty { return .result(["error": .string(Self.noItems(args))]) }
                let checked: [Checked]
                switch self.check(items, basis: false) {
                case .failure(let f): return .result(["error": .string(f.description)])
                case .success(let c): checked = c
                }
                switch self.compute(checked) {
                case .failure(let f): return .result(["error": .string(f.description)])
                case .success(let numbers):
                    draft = RecipeDraft(
                        ingredients: zip(checked, numbers).map { c, n in
                            .init(fdcID: n.fdcID, said: c.it["said"]?.string, note: c.it["note"]?.string,
                                  description: n.description, grams0: n.grams, values0: n.values, grams: n.grams)
                        },
                        leftOut: (args["left_out"]?.array ?? []).map {
                            ($0["said"]?.string ?? "", $0["reason"]?.string ?? "")
                        })
                    return .done
                }
            default:
                return .result(["error": .string("unknown tool \(tool)")])
            }
        }
        guard let draft else { throw Failure(description: "the model finished without the ingredients") }
        return draft
    }

    // MARK: - combining entries

    /// brain.py's name_combined: what foods being combined into one entry make
    /// ("Guacamole"), steered by what the user said about them, if anything.
    func nameCombined(_ items: [LogDB.Item], said: String?) async throws -> String {
        let p = try await client.route(profiles.profiles, needsVision: false)
        return try await nameCombined(items, said: said) { req, w in try await self.client.send(req, via: p, onWait: w) }
    }

    func nameCombined(_ items: [LogDB.Item], said: String?, send: Send) async throws -> String {
        let said = said?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = brain.combinePrompt + "\n\nFoods:\n"
            + items.map { "\(fmt($0.grams)) g \($0.said ?? $0.description)" }.joined(separator: "\n")
            + (said?.isEmpty == false ? "\n\nThe user says: \(said!)" : "")
        let reply = try await send(LLM.Request(messages: [.user(text)], jsonSchema: ("combine", brain.combineSchema)), { _ in })
        guard let out = try? JSON.parse(reply.text), case .object = out else {
            throw Failure(description: "combine namer returned non-JSON: \(reply.text.prefix(200))")
        }
        guard let name = out["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw Failure(description: "the model gave no name")
        }
        return name
    }

    // MARK: - package labels

    /// What a Nutrition Facts photo says, per serving, for the add-food form.
    struct Label: Equatable {
        var name: String?
        var servingLabel: String?
        var servingG: Double?
        var perServing: FoodDB.Nutrients
    }

    /// What a recipe photo says, for the recipe form.
    struct RecipePhoto: Equatable {
        var name: String?
        /// One ingredient per line.
        var text: String
    }

    /// brain.py's read_recipe_photo: the user checks the text before the
    /// ingredients are looked up.
    func readRecipePhoto(_ jpeg: Data) async throws -> RecipePhoto {
        let p = try await client.route(profiles.profiles, needsVision: true)
        return try await readRecipePhoto(jpeg) { req, w in try await self.client.send(req, via: p, onWait: w) }
    }

    func readRecipePhoto(_ jpeg: Data, send: Send) async throws -> RecipePhoto {
        let out = try await readPhoto(jpeg, brain.recipePhotoPrompt, "recipe", brain.recipePhotoSchema, send: send)
        let lines: [String] = if case .array(let a)? = out["ingredients"] {
            a.compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else { [] }
        guard case .bool(true)? = out["readable"], !lines.isEmpty else {
            throw Failure(description: "Couldn't read a recipe in that photo. Try again closer, in good light, "
                                       + "with the ingredient list in view.")
        }
        return RecipePhoto(name: out["name"]?.string, text: lines.joined(separator: "\n"))
    }

    /// One photo + instructions -> the model's JSON, held to `schema`.
    private func readPhoto(_ jpeg: Data, _ prompt: String, _ name: String, _ schema: JSON, send: Send) async throws -> JSON {
        let reply = try await send(LLM.Request(messages: [.user([.text(prompt), .jpeg(jpeg)])], jsonSchema: (name, schema)),
                                   { _ in })
        guard let out = try? JSON.parse(reply.text), case .object = out else {
            throw Failure(description: "\(name) reader returned non-JSON: \(reply.text.prefix(200))")
        }
        return out
    }

    /// brain.py's read_label: the user checks the numbers before saving.
    func readLabel(_ jpeg: Data) async throws -> Label {
        let p = try await client.route(profiles.profiles, needsVision: true)
        return try await readLabel(jpeg) { req, w in try await self.client.send(req, via: p, onWait: w) }
    }

    func readLabel(_ jpeg: Data, send: Send) async throws -> Label {
        let out = try await readPhoto(jpeg, brain.labelPrompt, "label", brain.labelSchema, send: send)
        guard case .bool(true)? = out["readable"] else {
            throw Failure(description: "That doesn't look like a readable Nutrition Facts label. "
                                       + "Try again closer, in good light.")
        }
        return Label(name: out["name"]?.string, servingLabel: out["serving_label"]?.string,
                     servingG: out["serving_g"]?.double,
                     perServing: Dictionary(uniqueKeysWithValues: FoodDB.nutrientKeys.map { ($0, out[$0]?.double) }))
    }

    // MARK: - edits by hand (app.py's item routes)

    /// New grams and/or another food for an item. Another food starts from its
    /// own numbers: the version was made for the old one.
    func editItem(_ item: LogDB.Item, grams: Double? = nil, fdcID: Int? = nil) throws {
        if let g = grams, g <= 0 { throw Failure(description: "Enter grams above zero.") }
        let swapped = fdcID != nil && fdcID != item.fdcID
        let adjust = swapped ? nil : item.adjust
        let id = fdcID ?? item.fdcID
        let n = try foods.compute([(.init(fdcID: id, grams: grams ?? item.grams), adjust)])[0]
        try log.setItem(item.id, .init(fdcID: id, description: n.description, said: item.said, grams: n.grams,
                                       basis: grams != nil ? "weighed" : item.basis, note: swapped ? nil : item.note,
                                       adjust: adjust, values: n.values))
    }

    // MARK: - JSON for the model

    static func json(_ n: FoodDB.Nutrients) -> JSON {
        .object(n.mapValues { $0.map(JSON.number) ?? .null })
    }

    static func json(_ h: FoodDB.Hit) -> JSON {
        var o: JSON = ["fdc_id": .number(Double(h.fdcID)), "description": .string(h.description), "source": .string(h.source),
                       "category": h.category.map(JSON.string) ?? .null, "kcal": .number(h.kcal),
                       "protein_g": .number(h.proteinG), "fat_g": .number(h.fatG), "carb_g": .number(h.carbG)]
        if let m = h.missing { o = o.merging(["missing": .array(m.map(JSON.string))]) }
        return o
    }
}

/// json.dumps of an object with its keys in this order (the edit prompt lists
/// items as brain.py writes them).
func pyDumps(_ pairs: [(String, JSON)]) throws -> String {
    "{" + (try pairs.map { "\(try JSON.string($0.0).text()): \(try $0.1.text())" }).joined(separator: ", ") + "}"
}
