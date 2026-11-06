import Charts
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
    @State private var saving: LogDB.Entry?
    @State private var editing: LogDB.Item?
    /// Combining: picking entries with checkmarks, or pinching two together
    /// (they and every entry between them).
    @State private var selecting = false
    @State private var picked: Set<Int64> = []
    @State private var combining: Combining?
    @State private var pinched: [Int64] = []
    @State private var pinchReady = false
    @State private var frames = RowFrames()
    @State private var recorder = Recorder()
    @State private var keyboard = false
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var phase

    private var log: LogDB { model.log }

    var body: some View {
        let _ = log.revision  // redraw on every write
        let loaded = Result { (try log.entries(day: day), try log.totals(day: day)) }
        let shown = ((try? loaded.get().0) ?? []).reversed() as [LogDB.Entry]
        let settled = shown.filter(EntryDetail.settled).count
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
                ForEach(shown) { e in
                    let isOpen = !selecting && (open.contains(e.id) || e.status == .error || e.pendingEdit != nil)
                    Section {
                        row(e, open: isOpen, combinable: settled >= 2)
                        if isOpen {
                            EntryDetail(entry: e, model: model, change: { changing = e.id }, saveRecipe: { saving = e },
                                        edit: { editing = $0 })
                        }
                    } header: {
                        if e.id == shown.first?.id { combineBar(shown) }
                    }
                }
            }
            if let writeError { Text(writeError).foregroundStyle(.red) }
        }
        .gesture(EntryPinch(qualify: { a, b in startPinch(a, b, shown) }, frames: frames,
                            changed: { scale in
                                let ready = scale < EntryPinch.threshold
                                if ready != pinchReady { pinchReady = ready }
                            },
                            ended: { combine in
                                // the pinched stay picked: swipe one right to combine them
                                if combine { selecting = true; picked.formUnion(pinched) }
                                pinched = []
                                pinchReady = false
                            }))
        .onChange(of: day) { selecting = false; picked = []; frames.frames = [:] }
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
        .sheet(item: $combining) { c in
            NavigationStack { CombineSheet(ids: c.ids, model: model) { selecting = false; picked = [] } }
        }
        .sheet(item: $saving) { e in
            NavigationStack { SaveRecipeSheet(entry: e, model: model) }
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

    /// Hold to talk is the main way in, in the middle, where a thumb reaches
    /// holding the phone in either hand; the camera adds a photo; the keyboard
    /// button types instead (quiet places, and the Simulator, which has no
    /// speech model).
    private var composer: some View {
        VStack(spacing: 6) {
            RecordingBanner(recorder: recorder)
            if keyboard {
                HStack(alignment: .bottom, spacing: 10) {
                    photoButton
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
                }
            } else {
                ZStack {
                    HoldToTalk(recorder: recorder, size: 64, labeled: true) { url in add(audioFile: url) }
                    HStack {
                        photoButton
                        Spacer()
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
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private var photoButton: some View {
        PhotoButton(maxSide: 1280, onPhoto: { photo = $0 }) {
            Image(systemName: "camera.circle.fill").font(.system(size: 44))
        }
        .accessibilityLabel("Photo")
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

    /// One entry's row: tap opens it, or picks it while combining; swipe to
    /// delete or change, or right to combine the picked; long-press for those
    /// and Combine. Highlighted while pinched and while picked.
    @ViewBuilder private func row(_ e: LogDB.Entry, open isOpen: Bool, combinable: Bool) -> some View {
        let canPick = EntryDetail.settled(e)
        Button {
            if !selecting { toggle(e.id) } else if canPick { picked.formSymmetricDifference([e.id]) }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: picked.contains(e.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(canPick ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                EntryRow(entry: e, open: isOpen)
            }
        }
        .foregroundStyle(.primary)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.frames[e.id] = $0 }
        .listRowBackground(pinched.contains(e.id) ? Color.accentColor.opacity(pinchReady ? 0.35 : 0.15)
                           : selecting && picked.contains(e.id) ? Color.accentColor.opacity(0.15)
                           : Color(.secondarySystemGroupedBackground))
        .swipeActions { if !selecting { Button("Delete", role: .destructive) { delete(e.id) } } }
        .swipeActions(edge: .leading) {
            if !selecting && canPick {
                Button { changing = e.id } label: { Label("Change", systemImage: "pencil") }.tint(.blue)
            } else if selecting && picked.contains(e.id) && picked.count >= 2 {
                Button { combining = Combining(ids: picked.sorted()) } label: {
                    Label("Combine", systemImage: "arrow.down.right.and.arrow.up.left")
                }.tint(.blue)
            }
        }
        .accessibilityAddTraits(selecting && picked.contains(e.id) ? .isSelected : [])
        .contextMenu {
            if !selecting && canPick {
                Button { changing = e.id } label: { Label("Change", systemImage: "pencil") }
                if combinable {
                    Button { selecting = true; picked = [e.id] } label: {
                        Label("Combine with others…", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
            }
            if !selecting { Button(role: .destructive) { delete(e.id) } label: { Label("Delete", systemImage: "trash") } }
        }
    }

    /// Above the entries while picking: Cancel, and Combine the picked. Picking
    /// starts from an entry's long-press menu, so it takes no room otherwise.
    @ViewBuilder private func combineBar(_ shown: [LogDB.Entry]) -> some View {
        if selecting {
            HStack {
                Button("Cancel") { selecting = false; picked = [] }
                Spacer()
                Text(picked.count < 2 ? "Pick entries to combine" : "\(picked.count) picked").foregroundStyle(.secondary)
                Spacer()
                Button("Combine") { combining = Combining(ids: shown.map(\.id).filter(picked.contains)) }
                    .fontWeight(.semibold).disabled(picked.count < 2)
            }
            .textCase(nil)
        }
    }

    /// A pinch begins on two entries: it covers them and every entry between,
    /// and only when all of those are done logging.
    private func startPinch(_ a: Int64, _ b: Int64, _ shown: [LogDB.Entry]) -> Bool {
        guard let i = shown.firstIndex(where: { $0.id == a }), let j = shown.firstIndex(where: { $0.id == b }) else {
            return false
        }
        let range = shown[min(i, j)...max(i, j)]
        guard range.allSatisfy(EntryDetail.settled) else { return false }
        pinched = range.map(\.id)
        pinchReady = false
        return true
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
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(kcal.rounded()))").font(.system(size: 40, weight: .semibold, design: .rounded))
                    Text(kcalGoal > 0 ? "of \(Int(kcalGoal)) kcal" : "kcal").foregroundStyle(.secondary)
                }
                Spacer()
                MacroRing(totals: totals).frame(width: 56, height: 56)
            }
            if kcalGoal > 0 {
                ProgressView(value: min(kcal, kcalGoal), total: kcalGoal).tint(kcal > kcalGoal ? .red : .accentColor)
                Text(kcal > kcalGoal ? "\(Int((kcal - kcalGoal).rounded())) over" : "\(Int((kcalGoal - kcal).rounded())) left")
                    .font(.callout).foregroundStyle(kcal > kcalGoal ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack {
                macro("Protein", "protein_g", goal: proteinGoal)
                macro("Fat", "fat_g")
                macro("Carbs", "carb_g")
            }
        }
    }

    private func macro(_ name: String, _ key: String, goal: Double = 0) -> some View {
        let g = totals[key] ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(Macro.color(key)).frame(width: 8, height: 8)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(fmt(g)) g").font(.headline.monospacedDigit())
                + Text(goal > 0 ? " of \(Int(goal))" : "").font(.caption).foregroundStyle(.secondary)
            // a bar only toward a target the user set: without one there's nothing to measure against
            if goal > 0 { ProgressView(value: min(1, g / goal)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The macros' colors, the web app's (--p, --f, --c), light and dark.
enum Macro {
    static func color(_ key: String) -> Color {
        switch key {
        case "protein_g": dynamic(0x3f7fbf, 0x7fb2e5)
        case "fat_g": dynamic(0xc9952b, 0xe5c06a)
        default: dynamic(0x3f8f47, 0x8fd18a)
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

/// Where the day's calories came from: protein, fat and carbs (4/9/4 kcal per g),
/// as a ring. Empty until something's logged.
struct MacroRing: View {
    let totals: [String: Double]

    var body: some View {
        let parts = [("protein_g", 4.0), ("fat_g", 9.0), ("carb_g", 4.0)].map { ($0.0, (totals[$0.0] ?? 0) * $0.1) }
        let all = parts.reduce(0) { $0 + $1.1 }
        if all > 0 {
            Chart(parts, id: \.0) { key, kcal in
                SectorMark(angle: .value("kcal", kcal), innerRadius: .ratio(0.6), angularInset: 1)
                    .foregroundStyle(Macro.color(key))
            }
            .chartLegend(.hidden)
            .accessibilityElement()
            .accessibilityLabel("Calories: " + zip(["protein", "fat", "carbs"], parts).map {
                "\(Int(($1.1 / all * 100).rounded()))% \($0)"
            }.joined(separator: ", "))
        }
    }
}

/// An entry id as a sheet's item.
private struct Opened: Identifiable { let id: Int64 }

/// The entries a Combine sheet is for.
private struct Combining: Identifiable {
    let ids: [Int64]
    var id: [Int64] { ids }
}

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
                    // plain text colors: a button tints its whole label, which washed the macros out
                    Button { open(d.day) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(TodayView.date(d.day)?.formatted(.dateTime.weekday(.wide).month().day()) ?? d.day)
                                HStack(spacing: 12) {
                                    macro("protein_g", d.proteinG)
                                    macro("fat_g", d.fatG)
                                    macro("carb_g", d.carbG)
                                }
                            }
                            Spacer()
                            Text("\(Int(d.kcal.rounded())) kcal").font(.headline.monospacedDigit())
                        }
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("\(TodayView.date(d.day)?.formatted(.dateTime.weekday(.wide).month().day()) ?? d.day), "
                                        + "\(Int(d.kcal.rounded())) calories, protein \(fmt(d.proteinG)) grams, "
                                        + "fat \(fmt(d.fatG)) grams, carbs \(fmt(d.carbG)) grams")
                }
                if days.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A macro's grams beside its color dot, as the day's totals show them.
    private func macro(_ key: String, _ g: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Macro.color(key)).frame(width: 7, height: 7)
            Text("\(fmt(g)) g").monospacedDigit()
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }
}
