import SwiftUI

/// What an entry shows when opened in the day's list, as rows under its
/// summary: which model logged it, actions, the photo, what was said, the
/// items, and the model's notes. Tapping an item opens it.
struct EntryDetail: View {
    let entry: LogDB.Entry
    let model: AppModel
    let change: () -> Void
    let saveRecipe: () -> Void
    let edit: (LogDB.Item) -> Void
    @State private var confirmDelete = false
    @State private var actionError: String?

    private var e: LogDB.Entry { entry }
    /// Logged and not mid-change: it can be changed or saved as a recipe.
    static func settled(_ e: LogDB.Entry) -> Bool { e.status == .done && e.pendingEdit == nil }

    var body: some View {
        // the row above already shows the time and meal
        if let m = e.model { Text("Logged by \(m)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        // equal columns, icon over word: they fit side by side on any phone
        HStack(spacing: 0) {
            if Self.settled(e) {
                Button(action: change) { Self.tile("Change", "pencil") }
            }
            if ![.thinking, .transcribing, .waiting].contains(e.status) {
                Menu {
                    Button { redo(nil) } label: { Label("First model that answers", systemImage: "arrow.clockwise") }
                    Section("With") {
                        ForEach(model.profiles.profiles.filter(\.enabled)) { p in
                            Button { redo(p.id) } label: {
                                Text(p.name)
                                Text(e.photo != nil && !p.vision ? "Can't read photos" : p.model)
                            }
                            .disabled(e.photo != nil && !p.vision)
                        }
                    }
                } label: {
                    Self.tile(e.status == .done ? "Redo" : "Try again", "arrow.clockwise")
                }
            }
            if Self.settled(e) && !e.items.isEmpty {
                Button(action: saveRecipe) { Self.tile("Save", "square.and.arrow.down") }
                    .accessibilityLabel("Save as a recipe")
            }
            Button(role: .destructive) { confirmDelete = true } label: { Self.tile("Delete", "trash") }
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { act { try model.log.deleteEntry(e.id) } }
        }
        if let actionError { Text(actionError).font(.callout).foregroundStyle(.red) }

        if let p = e.photo, let url = try? Media.url(p), let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFit().clipShape(.rect(cornerRadius: 10))
        }
        if !e.said.isEmpty || !e.edits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !e.said.isEmpty { Text("\u{201C}\(e.said)\u{201D}") }
                ForEach(e.edits, id: \.self) { Text("Changed: \u{201C}\($0)\u{201D}") }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        if let edit = e.pendingEdit {
            Label("Changing: \u{201C}\(edit)\u{201D}", systemImage: "pencil").font(.callout)
        }
        if let err = e.error {
            Text(err).font(.callout).foregroundStyle(e.status == .queued || e.status == .done ? .orange : .red)
        }
        ForEach(e.items) { it in
            Button { edit(it) } label: { ItemRow(item: it) }.foregroundStyle(.primary)
        }
        if e.items.count > 1 {
            HStack {
                Text("P \(fmt(e.total("protein_g"))) · F \(fmt(e.total("fat_g"))) · C \(fmt(e.total("carb_g")))")
                Spacer()
                Text("\(Int(e.kcal.rounded())) kcal").fontWeight(.semibold)
            }
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        if let r = e.reply, e.status == .done || e.status == .nothing {
            Text(r).font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func tile(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.body.weight(.medium)).frame(height: 22)
            Text(title).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    private func redo(_ profile: UUID?) {
        act { try model.log.redo(e.id, profile: profile); model.logger.kick() }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); actionError = nil } catch { actionError = String(describing: error) }
    }
}

struct ItemRow: View {
    let item: LogDB.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.said ?? item.description).font(.body.weight(.medium))
                Spacer()
                Text("\(Int(v("kcal").rounded())) kcal").monospacedDigit()
            }
            Text("\(item.basis == "estimated" ? "≈ " : "")\(fmt(item.grams)) g · \(item.description)")
                .font(.caption).foregroundStyle(.secondary)
            Text("P \(fmt(v("protein_g"))) · F \(fmt(v("fat_g"))) · C \(fmt(v("carb_g")))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let n = item.note { Text(n).font(.caption).foregroundStyle(.secondary) }
            if let a = item.adjust { Text(adjustText(a)).font(.caption).foregroundStyle(.blue) }
        }
    }

    private func v(_ k: String) -> Double { (item.values[k] ?? nil) ?? 0 }
}

/// A change to a logged entry, said or typed ("my recipe used 30% less fat");
/// the model re-logs the entry with it. Letting go of the mic sends the change
/// (with anything typed before it) and closes the sheet.
struct ChangeSheet: View {
    let id: Int64
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var recorder = Recorder()
    @State private var transcribing = false
    @State private var error: String?

    var body: some View {
        Form {
            if let e = try? model.log.entry(id) {
                Section { Text(e.what).foregroundStyle(.secondary) }
            }
            Section("What's different") {
                TextField("my recipe used 30% less oil · it was 90% dark chocolate · only half the rice",
                          text: $text, axis: .vertical)
                    .lineLimit(3...8)
                VStack(spacing: 6) {
                    HoldToTalk(recorder: recorder, size: 34) { url in spoken(url) }
                        .disabled(transcribing)
                        .frame(maxWidth: .infinity)
                    HStack {
                        if recorder.isRecording { RecordingBanner(recorder: recorder, hint: "release to change it") }
                        else if transcribing { ProgressView(); Text("Transcribing…").foregroundStyle(.secondary) }
                        else { Text("or hold to say it").font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Change this entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Change it") { send(text) }.disabled(transcribing)
            }
        }
    }

    private func spoken(_ url: URL) {
        transcribing = true
        Task {
            defer { transcribing = false }
            do {
                let words = try await Transcriber.transcribe(url).text
                try? FileManager.default.removeItem(at: url)
                let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                send(typed.isEmpty ? words : typed + " " + words)
            } catch {
                self.error = "Couldn't transcribe: \(error)"
            }
        }
    }

    private func send(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { error = "Say or type what to change."; return }
        do {
            try model.log.requestEdit(id, t)
            model.logger.kick()
            dismiss()
        } catch { self.error = String(describing: error) }
    }
}

/// One item: its grams, or another food in its place.
struct ItemSheet: View {
    let item: LogDB.Item
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ItemRow(item: item)
                if let a = item.adjust { Text(a.why).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                LabeledContent(item.basis == "estimated" ? "Grams (estimated)" : "Grams") {
                    TextField("grams", value: $grams, format: .number).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Button("Save") { act { try model.logger.editItem(item, grams: grams ?? 0) } }
                Button("Delete item", role: .destructive) { act { try model.log.deleteItem(item.id) } }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Text("Wrong food? Search for the right one:").font(.callout).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            FoodPicker(foods: model.foods) { hit in
                act { try model.logger.editItem(item, grams: grams ?? item.grams, fdcID: hit.fdcID) }
            }
        }
        .navigationTitle(item.said ?? item.description)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear { grams = pyRound(item.grams, 1) }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); dismiss() } catch { self.error = String(describing: error) }
    }
}

/// An entry's foods and amounts as one of your recipes: say its name next time
/// and it logs as one item. Versions ("90% cacao") come along.
struct SaveRecipeSheet: View {
    let entry: LogDB.Entry
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. My usual breakfast", text: $name)
                TextField("Other names you call it", text: $aliases)
            } footer: {
                Text("Say the name when logging and it logs as one item, these foods in these amounts. "
                     + "Edit it later in My foods and recipes.")
            }
            Section("What's in it") {
                ForEach(entry.items) { ItemRow(item: $0) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Save as a recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
    }

    private func save() {
        do {
            _ = try model.foods.addRecipe(name: name, aliases: aliases, text: Self.text(entry.items),
                                          ingredients: entry.items.map {
                                              .init(fdcID: $0.fdcID, grams: $0.grams, said: $0.said, adjust: $0.adjust)
                                          })
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    /// The recipe's ingredient list, one per line, as editing it shows them.
    static func text(_ items: [LogDB.Item]) -> String {
        items.map { i in
            "\(fmt(i.grams)) g \(i.said ?? i.description)" + (i.adjust.map { " (\($0.why))" } ?? "")
        }.joined(separator: "\n")
    }
}
