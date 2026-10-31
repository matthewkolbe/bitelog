import SwiftUI

/// What an entry shows when opened in the day's list, as rows under its
/// summary: actions, the photo, what was said, the items, and the model's notes.
/// Tapping an item opens it; the pencil changes the entry; ⋯ has the rest.
struct EntryDetail: View {
    let entry: LogDB.Entry
    let model: AppModel
    let change: () -> Void
    let add: () -> Void
    let edit: (LogDB.Item) -> Void
    @State private var confirmDelete = false
    @State private var actionError: String?

    private var e: LogDB.Entry { entry }

    var body: some View {
        HStack(spacing: 18) {
            Text([e.createdAt.formatted(date: .omitted, time: .shortened), e.meal, e.model].compactMap { $0 }
                .joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if e.status == .done && e.pendingEdit == nil {
                Button(action: change) { Image(systemName: "pencil") }
                    .accessibilityLabel("Change this entry")
            }
            Menu {
                if e.status == .done && e.pendingEdit == nil {
                    Button(action: add) { Label("Add a food", systemImage: "plus") }
                }
                if ![.thinking, .transcribing, .waiting].contains(e.status) {
                    Button { act { try model.log.redo(e.id); model.logger.kick() } } label: {
                        Label(e.status == .done ? "Redo with the model" : "Try again", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete entry", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(.rect)
            }
            .accessibilityLabel("Entry options")
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
                HStack(spacing: 12) {
                    HoldToTalk(recorder: recorder, size: 34) { url in spoken(url) }
                        .disabled(transcribing)
                    if recorder.isRecording { RecordingBanner(recorder: recorder, hint: "release to change it") }
                    else if transcribing { ProgressView(); Text("Transcribing…").foregroundStyle(.secondary) }
                    else { Text("or hold to say it").font(.callout).foregroundStyle(.secondary) }
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
                let words = try await Transcriber.transcribe(url)
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
