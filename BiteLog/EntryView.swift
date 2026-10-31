import SwiftUI

/// One entry: what was said, typed or photographed, its items, and changes to it.
struct EntryView: View {
    let id: Int64
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var actionError: String?
    @State private var changing = false
    @State private var adding = false
    @State private var editing: LogDB.Item?
    @State private var confirmDelete = false

    private var log: LogDB { model.log }

    var body: some View {
        let _ = log.revision
        Form {
            switch Result(catching: { try log.entry(id) }) {
            case .failure(let e):
                Text(String(describing: e)).foregroundStyle(.red)
            case .success(nil):
                Text("This entry was deleted.")
            case .success(let e?):
                content(e)
            }
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $changing) {
            NavigationStack { ChangeSheet(id: id, model: model) }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { AddFoodSheet(entryID: id, model: model) }
        }
        .sheet(item: $editing) { item in
            NavigationStack { ItemSheet(item: item, model: model) }
        }
    }

    @ViewBuilder private func content(_ e: LogDB.Entry) -> some View {
        if let p = e.photo, let url = try? Media.url(p), let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFit().listRowInsets(EdgeInsets())
        }
        Section {
            if !e.said.isEmpty { Text("“\(e.said)”") }
            ForEach(e.edits, id: \.self) { Text("Changed: “\($0)”").foregroundStyle(.secondary) }
            LabeledContent("Logged", value: e.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let m = e.meal { LabeledContent("Meal", value: m) }
            if let m = e.model { LabeledContent("Model", value: m) }
        }
        if let edit = e.pendingEdit {
            Section { Label("Changing: “\(edit)”", systemImage: "pencil") }
        }
        if let err = e.error {
            Section { Text(err).foregroundStyle(e.status == .queued || e.status == .done ? .orange : .red) }
        }
        if let r = e.reply, e.status == .done || e.status == .nothing { Section("Assumptions") { Text(r) } }
        if !e.items.isEmpty {
            Section {
                ForEach(e.items) { it in
                    Button { editing = it } label: { ItemRow(item: it) }.foregroundStyle(.primary)
                }
            } header: {
                Text("Items")
            } footer: {
                Text("\(Int(e.kcal.rounded())) kcal · P \(fmt(e.total("protein_g"))) · F \(fmt(e.total("fat_g"))) · "
                     + "C \(fmt(e.total("carb_g"))). Tap an item to change its grams or food.")
            }
        }
        Section {
            if e.status == .done && e.pendingEdit == nil {
                Button { changing = true } label: { Label("Change this entry", systemImage: "pencil") }
                Button { adding = true } label: { Label("Add a food", systemImage: "plus") }
            }
            if ![.thinking, .transcribing, .waiting].contains(e.status) {
                Button { act { try log.redo(id); model.logger.kick() } } label: {
                    Label(e.status == .done ? "Redo with the model" : "Try again", systemImage: "arrow.clockwise")
                }
            }
            Button("Delete entry", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { act { try log.deleteEntry(id); dismiss() } }
                }
            if let actionError { Text(actionError).foregroundStyle(.red) }
        }
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
/// the model re-logs the entry with it.
struct ChangeSheet: View {
    let id: Int64
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var recorder = Recorder()
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
                Dictation(recorder: recorder, text: $text)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Change this entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Change it") {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard t.count >= 2 else { error = "Say or type what to change."; return }
                    do {
                        try model.log.requestEdit(id, t)
                        model.logger.kick()
                        dismiss()
                    } catch { self.error = String(describing: error) }
                }
            }
        }
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

/// Add a food to an entry by hand: grams, then search.
struct AddFoodSheet: View {
    let entryID: Int64
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Grams") {
                    TextField("100", value: $grams, format: .number).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Enter the grams, then pick the food.")
            }
            if let error { Text(error).foregroundStyle(.red) }
            FoodPicker(foods: model.foods) { hit in
                do {
                    try model.logger.addItem(to: entryID, fdcID: hit.fdcID, grams: grams ?? 0)
                    dismiss()
                } catch { self.error = String(describing: error) }
            }
        }
        .navigationTitle("Add a food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
