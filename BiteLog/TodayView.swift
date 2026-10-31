import SwiftUI

/// One day's log: totals against your targets, entries, and a bar to say,
/// type or photograph what you ate.
struct TodayView: View {
    let model: AppModel

    @State private var day = LogDB.day(Date(), .current)
    @State private var text = ""
    @State private var writeError: String?
    @State private var photo: Data?
    @State private var history = false
    /// Entries opened in place, and the sheets opened from them.
    @State private var open: Set<Int64> = []
    @State private var changing: Int64?
    @State private var adding: Int64?
    @State private var editing: LogDB.Item?
    @State private var recorder = Recorder()
    @State private var keyboard = false
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var phase

    private var log: LogDB { model.log }

    var body: some View {
        let _ = log.revision  // redraw on every write
        let loaded = Result { (try log.entries(day: day), try log.totals(day: day)) }
        List {
            switch loaded {
            case .failure(let e):
                Text("Couldn't read the log: \(String(describing: e))").foregroundStyle(.red)
            case .success(let (entries, totals)):
                Section {
                    TotalsView(totals: totals)
                } footer: {
                    if entries.isEmpty {
                        Text(day == today ? "Hold the mic and say what you ate: “130 grams of grapes and a cup of whole milk.”"
                                          : "Nothing logged this day.")
                    }
                }
                // one card per entry: tap to open it in place
                ForEach(entries.reversed()) { e in
                    let isOpen = open.contains(e.id) || e.status == .error || e.pendingEdit != nil
                    Section {
                        Button { toggle(e.id) } label: { EntryRow(entry: e, open: isOpen) }
                            .foregroundStyle(.primary)
                            .swipeActions { Button("Delete", role: .destructive) { delete(e.id) } }
                        if isOpen {
                            EntryDetail(entry: e, model: model, change: { changing = e.id }, add: { adding = e.id },
                                        edit: { editing = $0 })
                        }
                    }
                }
            }
            if let writeError { Text(writeError).foregroundStyle(.red) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
            }
            ToolbarItem(placement: .principal) {
                Button { history = true } label: {
                    VStack(spacing: 0) {
                        Text(title).font(.headline)
                        Text(longDate).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("History")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next day").disabled(day >= today)
            }
        }
        .listSectionSpacing(10)
        .sheet(item: Binding(get: { changing.map(Opened.init) }, set: { changing = $0?.id })) { o in
            NavigationStack { ChangeSheet(id: o.id, model: model) }
        }
        .sheet(item: Binding(get: { adding.map(Opened.init) }, set: { adding = $0?.id })) { o in
            NavigationStack { AddFoodSheet(entryID: o.id, model: model) }
        }
        .sheet(item: $editing) { item in
            NavigationStack { ItemSheet(item: item, model: model) }
        }
        .sheet(isPresented: $history) {
            NavigationStack { HistoryView(log: log) { day = $0; history = false } }
        }
        .sheet(isPresented: Binding(get: { photo != nil }, set: { if !$0 { photo = nil } })) {
            if let photo {
                NavigationStack {
                    PhotoEntrySheet(jpeg: photo) { note, audio in add(text: note, audio: audio, photo: photo) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .onChange(of: phase) { _, p in if p == .active { model.logger.kick() } }
        .task {
            // entries waiting for a model are retried every 30 s while the app is open
            while !Task.isCancelled {
                model.logger.kick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Hold to talk is the main way in; the camera adds a photo; the keyboard
    /// button types instead (quiet places, and the Simulator, which has no
    /// speech model).
    private var composer: some View {
        VStack(spacing: 6) {
            RecordingBanner(recorder: recorder)
            HStack(alignment: .bottom, spacing: 10) {
                PhotoButton(maxSide: 1280, onPhoto: { photo = $0 }) {
                    Image(systemName: "camera.circle.fill").font(.system(size: 44))
                }
                .accessibilityLabel("Photo")
                if keyboard {
                    TextField("What did you eat?", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($typing)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(.background, in: .rect(cornerRadius: 20))
                    Button {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { keyboard = false } else { add(text: text) }
                    } label: {
                        Image(systemName: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? "mic.circle.fill" : "arrow.up.circle.fill").font(.system(size: 44))
                    }
                    .accessibilityLabel(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Talk instead" : "Log it")
                } else {
                    HoldToTalk(recorder: recorder, size: 44, pill: true) { url in add(audioFile: url) }
                    Button {
                        keyboard = true
                        typing = true
                    } label: {
                        Image(systemName: "keyboard").font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44).background(.background, in: .circle)
                    }
                    .accessibilityLabel("Type instead")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private var today: String { LogDB.day(Date(), .current) }

    private var title: String {
        if day == today { return "Today" }
        if let d = Self.date(day), Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return Self.date(day)?.formatted(.dateTime.weekday(.wide)) ?? day
    }

    private var longDate: String { Self.date(day)?.formatted(.dateTime.month(.wide).day()) ?? day }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    private func shift(_ days: Int) {
        guard let d = Self.date(day), let next = Calendar.current.date(byAdding: .day, value: days, to: d) else { return }
        day = LogDB.day(next, .current)
    }

    private func add(audioFile url: URL) {
        do {
            add(audio: try Media.adopt(url, ext: "wav"))
        } catch {
            writeError = "Couldn't keep the recording: \(error)"
        }
    }

    private func add(text: String? = nil, audio: String? = nil, photo: Data? = nil) {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let p = try photo.map { try Media.save($0, ext: "jpg") }
            _ = try log.addEntry(text: t?.isEmpty == false ? t : nil, audio: audio, photo: p)
            if text != nil { self.text = ""; keyboard = false }
            typing = false
            day = today
            writeError = nil
            model.logger.kick()
        } catch {
            writeError = "Couldn't save the entry: \(error)"
        }
    }

    private func toggle(_ id: Int64) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    private func delete(_ id: Int64) {
        do { try log.deleteEntry(id) } catch { writeError = "Couldn't delete: \(error)" }
    }
}

/// A photo about to be logged, with an optional typed or spoken note.
struct PhotoEntrySheet: View {
    let jpeg: Data
    let send: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var audio: String?
    @State private var recorder = Recorder()

    var body: some View {
        Form {
            if let img = UIImage(data: jpeg) {
                Image(uiImage: img).resizable().scaledToFit().clipShape(.rect(cornerRadius: 12))
                    .listRowInsets(EdgeInsets())
            }
            Section("Anything to add? (optional)") {
                TextField("about 200 g, cooked in olive oil", text: $note, axis: .vertical)
                HStack(spacing: 12) {
                    HoldToTalk(recorder: recorder, size: 34) { url in
                        Media.remove(audio)
                        audio = try? Media.adopt(url, ext: "wav")
                    }
                    if recorder.isRecording { RecordingBanner(recorder: recorder, hint: "release when done") }
                    else { Text(audio == nil ? "or hold to say it" : "Voice note added ✓").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { Media.remove(audio); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Estimate it") { send(note, audio); dismiss() }
            }
        }
    }
}

struct TotalsView: View {
    let totals: [String: Double]
    @AppStorage(Goals.kcalKey) private var kcalGoal = 0.0
    @AppStorage(Goals.proteinKey) private var proteinGoal = 0.0

    var body: some View {
        let kcal = totals["kcal"] ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(kcal.rounded()))").font(.system(size: 40, weight: .semibold, design: .rounded))
                Text(kcalGoal > 0 ? "of \(Int(kcalGoal)) kcal" : "kcal").foregroundStyle(.secondary)
                Spacer()
                if kcalGoal > 0 {
                    Text(kcal > kcalGoal ? "\(Int((kcal - kcalGoal).rounded())) over" : "\(Int((kcalGoal - kcal).rounded())) left")
                        .foregroundStyle(kcal > kcalGoal ? .red : .secondary)
                }
            }
            if kcalGoal > 0 {
                ProgressView(value: min(kcal, kcalGoal), total: kcalGoal).tint(kcal > kcalGoal ? .red : .accentColor)
            }
            HStack {
                macro("Protein", "protein_g", 4, goal: proteinGoal)
                macro("Fat", "fat_g", 9)
                macro("Carbs", "carb_g", 4)
            }
        }
    }

    private func macro(_ name: String, _ key: String, _ kcalPerG: Double, goal: Double = 0) -> some View {
        let g = totals[key] ?? 0
        let fromMacros = max(1, (totals["protein_g"] ?? 0) * 4 + (totals["fat_g"] ?? 0) * 9 + (totals["carb_g"] ?? 0) * 4)
        return VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text("\(fmt(g)) g").font(.headline.monospacedDigit())
                + Text(goal > 0 ? " of \(Int(goal))" : "").font(.caption).foregroundStyle(.secondary)
            // share of calories, or progress toward the target when there is one
            ProgressView(value: goal > 0 ? min(1, g / goal) : g * kcalPerG / fromMacros)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An entry id as a sheet's item.
private struct Opened: Identifiable { let id: Int64 }

struct EntryRow: View {
    let entry: LogDB.Entry
    var open = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let p = entry.photo, let url = try? Media.url(p), let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.what).lineLimit(2)
                status.font(.caption)
            }
            Spacer()
            if entry.status == .done {
                Text("\(Int(entry.kcal.rounded()))").font(.headline.monospacedDigit())
            } else if [.queued, .transcribing, .thinking, .waiting].contains(entry.status) && entry.error == nil {
                ProgressView()
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var status: some View {
        let time = entry.createdAt.formatted(date: .omitted, time: .shortened)
        if let edit = entry.pendingEdit {
            Label("Changing: “\(edit)”", systemImage: "pencil").foregroundStyle(.secondary).lineLimit(2)
        } else {
            switch entry.status {
            case .done:
                let macros = "P \(fmt(entry.total("protein_g"))) · F \(fmt(entry.total("fat_g"))) · C \(fmt(entry.total("carb_g")))"
                VStack(alignment: .leading, spacing: 2) {
                    Text([time, entry.meal, macros].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    if let err = entry.error { Text(err).foregroundStyle(.orange).lineLimit(2) }
                }
            case .transcribing:
                Text("\(time) · Transcribing…").foregroundStyle(.secondary)
            case .thinking:
                Text("\(time) · Thinking…").foregroundStyle(.secondary)
            case .waiting:
                Text("\(time) · The server asked us to wait…").foregroundStyle(.secondary)
            case .queued:
                Label(entry.error ?? "Queued", systemImage: "tray").foregroundStyle(.orange).lineLimit(2)
            case .nothing:
                Text("\(time) · \(entry.reply ?? "Nothing to log.")").foregroundStyle(.secondary)
            case .error:
                Label(entry.error ?? "Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

/// Every day with entries, newest first; tap one to open it.
struct HistoryView: View {
    let log: LogDB
    let open: (String) -> Void
    var body: some View {
        let _ = log.revision
        List {
            switch Result(catching: { try log.days(limit: 90) }) {
            case .failure(let e):
                Text(String(describing: e)).foregroundStyle(.red)
            case .success(let days):
                ForEach(days) { d in
                    Button { open(d.day) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(TodayView.date(d.day)?.formatted(.dateTime.weekday(.wide).month().day()) ?? d.day)
                                    .foregroundStyle(.primary)
                                Text("P \(fmt(d.proteinG)) F \(fmt(d.fatG)) C \(fmt(d.carbG))").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(Int(d.kcal.rounded()))").font(.headline.monospacedDigit()).frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                }
                if days.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}
