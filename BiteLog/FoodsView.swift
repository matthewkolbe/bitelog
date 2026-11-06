import SwiftUI

/// Your recipes, and products the food database doesn't have. The model finds
/// them by name (or the other names given) when logging.
struct FoodsView: View {
    let model: AppModel
    @State private var foods: [FoodDB.Custom] = []
    @State private var error: String?
    @State private var removing: FoodDB.Custom?

    var body: some View {
        List {
            Section {
                ForEach(foods, id: \.fdcID) { f in
                    NavigationLink {
                        if f.kind == "recipe" { RecipeEditor(model: model, editing: f, done: reload) }
                        else { ProductForm(model: model, editing: f, done: reload) }
                    } label: { row(f) }
                }
                .onDelete { offsets in removing = offsets.first.map { foods[$0] } }
                if foods.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
            } footer: {
                Text("Tap one to edit it. Say the name (or another name) when logging. Editing or removing one keeps "
                     + "entries already logged with it as they were.")
            }
            Section {
                NavigationLink { RecipeEditor(model: model, editing: nil, done: reload) } label: {
                    Label("Add a recipe", systemImage: "frying.pan")
                }
                NavigationLink { ProductForm(model: model, editing: nil, done: reload) } label: {
                    Label("Add a product from its label", systemImage: "barcode.viewfinder")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("My foods")
        .onAppear(perform: reload)
        .confirmationDialog("Remove \(removing?.description ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let f = removing {
                    do { try model.foods.removeCustomFood(f.fdcID) } catch { self.error = String(describing: error) }
                }
                removing = nil
                reload()
            }
        } message: {
            Text("Entries already logged with it keep their numbers.")
        }
    }

    private func row(_ f: FoodDB.Custom) -> some View {
        let v = { (k: String) in (f.perServing[k] ?? nil) ?? 0 }
        let serving = f.kind == "recipe" ? "serving \(fmt(f.servingG)) g" : f.servingLabel ?? "\(fmt(f.servingG)) g"
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(f.description)
                if f.kind == "recipe" { Text("recipe").font(.caption2).padding(.horizontal, 6).background(.quaternary, in: .capsule) }
            }
            Text("\(serving) · \(Int(v("kcal").rounded())) kcal · P \(fmt(v("protein_g"))) F \(fmt(v("fat_g"))) C \(fmt(v("carb_g")))"
                 + (f.aliases.isEmpty ? "" : " · “\(f.aliases)”"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reload() {
        do { foods = try model.foods.customFoods(); error = nil } catch { self.error = String(describing: error) }
    }
}

/// A packaged product from its Nutrition Facts label: photograph it to fill
/// the numbers in, check them, save. Editing one saves a new version and hides
/// the old.
struct ProductForm: View {
    let model: AppModel
    let editing: FoodDB.Custom?
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var servingLabel = ""
    @State private var servingG: Double?
    @State private var values: [String: Double] = [:]
    @State private var reading = false
    @State private var note: String?
    @State private var error: String?

    static let main = [("kcal", "Calories"), ("protein_g", "Protein (g)"), ("fat_g", "Fat (g)"), ("carb_g", "Carbs (g)")]
    static let more = [("fiber_g", "Fiber (g)"), ("sugar_g", "Sugars (g)"), ("sat_fat_g", "Sat. fat (g)"),
                       ("sodium_mg", "Sodium (mg)"), ("cholesterol_mg", "Cholesterol (mg)")]

    var body: some View {
        Form {
            Section {
                PhotoButton(maxSide: 2000, onPhoto: read) {
                    Label(reading ? "Reading the label…" : "Photograph the label", systemImage: "camera")
                }
                .disabled(reading)
                if reading { ProgressView() }
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            } footer: {
                Text("A model that reads photos fills the numbers in. Check them against the label.")
            }
            Section {
                TextField("Name, e.g. Oat granola bar", text: $name)
                TextField("Other names you call it: granola bar, bar", text: $aliases)
            }
            Section("Per serving") {
                number("Serving size (g)", $servingG)
                TextField("Serving as printed: 2 oz (56 g)", text: $servingLabel)
                ForEach(Self.main, id: \.0) { k, label in number(label, binding(k)) }
            }
            Section("More from the label (optional)") {
                ForEach(Self.more, id: \.0) { k, label in number(label, binding(k)) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(editing != nil ? "Edit product" : "Add a product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(editing != nil ? "Save changes" : "Add food", action: save) }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let f = editing, name.isEmpty else { return }
        name = f.description
        aliases = f.aliases
        servingLabel = f.servingLabel ?? ""
        servingG = f.servingG
        for k in FoodDB.nutrientKeys { if let v = f.perServing[k] ?? nil { values[k] = v } }
    }

    private func number(_ label: String, _ v: Binding<Double?>) -> some View {
        LabeledContent(label) {
            TextField("", value: v, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }

    private func binding(_ k: String) -> Binding<Double?> {
        Binding(get: { values[k] }, set: { values[k] = $0 })
    }

    private func read(_ jpeg: Data) {
        reading = true
        error = nil
        Task {
            defer { reading = false }
            do {
                let l = try await model.logger.readLabel(jpeg)
                if let n = l.name { name = n }
                if let s = l.servingLabel { servingLabel = s }
                if let g = l.servingG { servingG = g }
                for k in FoodDB.nutrientKeys { if let v = l.perServing[k] ?? nil { values[k] = v } }
                note = "Check the numbers against the label, name it, then Add food."
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    private func save() {
        guard name.trimmingCharacters(in: .whitespaces).count >= 2 else { error = "Enter a name."; return }
        guard let g = servingG, g > 0 else { error = "Enter the serving size."; return }
        for (k, label) in Self.main where values[k] == nil { error = "Enter the \(label.lowercased())."; return }
        do {
            _ = try model.foods.addCustomFood(
                name: name, aliases: aliases, servingLabel: servingLabel.isEmpty ? nil : servingLabel, servingG: g,
                perServing: Dictionary(uniqueKeysWithValues: FoodDB.nutrientKeys.map { ($0, values[$0]) }),
                replaces: editing?.fdcID)
            done()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// A recipe: your ingredient list -> the model's breakdown into foods, saved as
/// one of your foods: the whole recipe, by its weight, so any amount eaten is
/// grams of it. Editing one saves a new version and hides the old.
struct RecipeEditor: View {
    let model: AppModel
    let editing: FoodDB.Custom?
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var text = ""
    @State private var cookedG: Double?
    @State private var task: Task<Void, Never>?
    @State private var reading = false
    @State private var error: String?
    @State private var recorder = Recorder()
    private var working: Bool { task != nil }

    var body: some View {
        Form {
            Section {
                PhotoButton(maxSide: 2000, onPhoto: readPhoto) {
                    Label(reading ? "Reading the recipe…" : "Photograph a recipe", systemImage: "camera")
                }
                .disabled(reading || working)
                if reading { ProgressView() }
            } footer: {
                Text("A model that reads photos copies the ingredients in. A recipe over two pages takes two photos.")
            }
            Section {
                TextField("Name, e.g. My miso soup", text: $name)
                TextField("Other names you call it", text: $aliases)
            } footer: {
                Text("List what goes in, with amounts. Saving looks each ingredient up.")
            }
            Section("Ingredients") {
                TextField("1 tbsp white miso\n150 g firm tofu\n2 scallions\n350 g water", text: $text, axis: .vertical)
                    .lineLimit(5...20)
                Dictation(recorder: recorder, text: $text, separator: "\n")
            }
            Section {
                LabeledContent("Finished weight (g)") {
                    TextField("optional: weigh the pot", value: $cookedG, format: .number).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            if working { HStack { ProgressView(); Text("Looking up ingredients…") } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .disabled(working)
        .navigationTitle(editing != nil ? "Edit recipe" : "Add a recipe")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            // cancelling while it works stops the lookup; nothing is saved
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { task?.cancel(); dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(working ? "Saving…" : "Save", action: save).disabled(working || reading)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let f = editing, name.isEmpty, let r = f.recipe else { return }
        name = f.description
        aliases = f.aliases
        text = r["text"]?.string ?? ""
        cookedG = r["cooked_g"]?.double
    }

    /// Fills an empty name; the ingredients go after any already there, so a
    /// recipe over two pages takes two photos.
    private func readPhoto(_ jpeg: Data) {
        reading = true
        error = nil
        Task {
            defer { reading = false }
            do {
                let r = try await model.logger.readRecipePhoto(jpeg)
                if let n = r.name, name.trimmingCharacters(in: .whitespaces).isEmpty { name = n }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = t.isEmpty ? r.text : t + "\n" + r.text
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count >= 2 else { error = "Name the recipe."; return }
        guard t.count >= 3 else { error = "List the ingredients."; return }
        error = nil
        task = Task {
            defer { task = nil }
            do {
                let d = try await model.logger.recipe(name: n, text: t)
                try Task.checkCancellation()
                _ = try model.foods.addRecipe(name: n, aliases: aliases, text: t, cookedG: cookedG,
                                              ingredients: d.ingredients.map { .init(fdcID: $0.fdcID, grams: $0.grams, said: $0.said) },
                                              replaces: editing?.fdcID)
                done()
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
