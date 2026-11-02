import SwiftUI
import UniformTypeIdentifiers

/// The models the app may use, in the order each entry tries them.
struct SettingsView: View {
    let model: AppModel
    @Bindable var store: ProfileStore
    let client: LLMClient
    @State private var routeResult: String?
    @State private var checking = false
    @AppStorage(Goals.kcalKey) private var kcalGoal = 0.0
    @AppStorage(Goals.proteinKey) private var proteinGoal = 0.0

    var body: some View {
        List {
            Section {
                LabeledContent("Calories per day") {
                    TextField("none", value: goal($kcalGoal), format: .number).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Protein per day (g)") {
                    TextField("none", value: goal($proteinGoal), format: .number).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Daily targets")
            } footer: {
                Text("They drive the bars on the day's summary.")
            }

            DataSection(model: model)

            Section {
                NavigationLink { FoodsView(model: model) } label: { Label("My foods and recipes", systemImage: "basket") }
                NavigationLink {
                    IntroView { EmptyView() }.navigationBarTitleDisplayMode(.inline)
                } label: { Label("How Bite Log works", systemImage: "questionmark.circle") }
                NavigationLink { GuideList() } label: { Label("Model guides", systemImage: "list.number") }
            }

            Section {
                ForEach(store.profiles) { p in
                    NavigationLink(value: p.id) { row(p) }
                }
                .onMove { store.profiles.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for i in offsets { client.keychain.removeKey(for: store.profiles[i].id) }
                    store.profiles.remove(atOffsets: offsets)
                }
                Menu {
                    ForEach(Preset.all) { preset in
                        Button {
                            var p = preset.profile
                            p.id = UUID()
                            store.profiles.append(p)
                        } label: {
                            Text(preset.title)
                            Text(preset.detail)
                        }
                    }
                } label: {
                    // the whole row opens the menu, not just the words
                    Label("Add a model", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Each entry uses the first model here that's switched on and answers, top to bottom. "
                     + "Drag to reorder. Keys stay on this phone. Removing the last one returns to setup.")
            }

            Section {
                Button(checking ? "Checking…" : "Which model would I get now?") {
                    Task {
                        checking = true
                        defer { checking = false }
                        do {
                            let p = try await client.route(store.profiles, needsVision: false)
                            routeResult = "\(p.name) (\(p.model))"
                        } catch {
                            routeResult = String(describing: error)
                        }
                    }
                }
                .disabled(checking || store.profiles.isEmpty)
                if let routeResult { Text(routeResult).font(.callout).foregroundStyle(.secondary) }
            }

            if let e = store.saveError {
                Text(e).foregroundStyle(.red)
            }
        }
        .navigationTitle("Settings")
        .toolbar { if !store.profiles.isEmpty { EditButton() } }
        .navigationDestination(for: UUID.self) { id in
            if let i = store.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditor(profile: $store.profiles[i], client: client) {
                    client.keychain.removeKey(for: id)
                    store.profiles.removeAll { $0.id == id }
                }
            }
        }
    }

    /// A target as an optional number: 0 is shown as empty.
    private func goal(_ v: Binding<Double>) -> Binding<Double?> {
        Binding(get: { v.wrappedValue > 0 ? v.wrappedValue : nil }, set: { v.wrappedValue = max(0, $0 ?? 0) })
    }

    private func row(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(p.name)
                if !p.enabled { Text("off").font(.caption).foregroundStyle(.secondary) }
            }
            Text("\(p.model.isEmpty ? "no model set" : p.model) · \(p.kind.title)")
                .font(.caption).foregroundStyle(.secondary)
            let day = client.limiter.today(p)
            if day.requests > 0 {
                Text("today: \(count(day.requests, "request")), \(count(day.tokens, "token"))"
                     + (p.limits.tokensPerDay.map { " of \($0.formatted())" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(p.enabled ? 1 : 0.5)
    }
}

struct ProfileEditor: View {
    @Binding var profile: Profile
    let client: LLMClient
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var keyError: String?
    @State private var extraText = ""
    @State private var extraError: String?
    @State private var models: [String] = []
    @State private var modelsError: String?
    @State private var test: TestState = .idle

    enum TestState {
        case idle, running
        case passed(String)
        case failed(String)
    }

    var body: some View {
        form
    }

    private var nameSection: some View {
        Section {
            TextField("Name", text: $profile.name)
            Toggle("Use this model", isOn: $profile.enabled)
        }
    }

    private var testSection: some View {
        Section {
            Button("Test connection") { Task { await runTest() } }
                .disabled(isRunning)
            switch test {
            case .idle: EmptyView()
            case .running: ProgressView()
            case .passed(let m): Label(m, systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let m): Label(m, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
    }

    private var removeSection: some View {
        Section {
            Button("Remove this model", role: .destructive) {
                dismiss()
                delete()
            }
        }
    }

    private var form: some View {
        Form {
            nameSection

            Section {
                Picker("API", selection: $profile.kind) {
                    ForEach(Profile.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Server address", text: $profile.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(profile.kind == .anthropic ? "API key" : "API key (if the server needs one)", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: key) { _, new in
                        do {
                            try client.keychain.setKey(new, for: profile.id)
                            keyError = nil
                        } catch {
                            keyError = String(describing: error)
                        }
                    }
                if let keyError { Text(keyError).foregroundStyle(.red) }
            } header: {
                Text("Connection")
            } footer: {
                Text("The address up to and including the version, like https://api.anthropic.com/v1 "
                     + "or http://my-computer.local:8080/v1.")
            }

            Section {
                TextField("Model id", text: $profile.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Choose from the server's list") {
                    Task {
                        do {
                            models = try await client.models(profile)
                            modelsError = models.isEmpty ? "The server lists no models." : nil
                        } catch {
                            modelsError = String(describing: error)
                        }
                    }
                }
                if !models.isEmpty {
                    Picker("Server's models", selection: $profile.model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        if !models.contains(profile.model) { Text(profile.model).tag(profile.model) }
                    }
                }
                if let modelsError { Text(modelsError).foregroundStyle(.red) }
                Toggle("Reads photos", isOn: $profile.vision)
            } header: {
                Text("Model")
            } footer: {
                Text("Photo entries skip models that can't read photos.")
            }

            Section {
                LabeledContent("Requests per minute") {
                    TextField("no limit", value: $profile.limits.requestsPerMinute, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Tokens per day") {
                    TextField("no limit", value: $profile.limits.tokensPerDay, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                let day = client.limiter.today(profile)
                LabeledContent("Used today", value: "\(count(day.requests, "request")), \(count(day.tokens, "token"))")
            } header: {
                Text("Limits")
            } footer: {
                Text("Past the per-minute limit, requests wait. At the daily token limit, entries use the next "
                     + "model in the list until tomorrow. Logging one meal is usually a few requests.")
            }

            Section {
                TextEditor(text: $extraText)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .frame(minHeight: 90)
                    .onChange(of: extraText) { _, new in applyExtra(new) }
                if let extraError { Text(extraError).foregroundStyle(.red) }
            } header: {
                Text("Extra request fields")
            } footer: {
                Text("JSON added to every request, e.g. sampling settings: {\"temperature\": 0.6}.")
            }

            testSection
            removeSection
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                key = try client.keychain.key(for: profile.id) ?? ""
            } catch {
                keyError = String(describing: error)
            }
            extraText = (try? profile.extra.text(pretty: true)) ?? "{}"
        }
    }

    private var isRunning: Bool { if case .running = test { true } else { false } }

    private func applyExtra(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let j = trimmed.isEmpty ? JSON.object([:]) : try JSON.parse(trimmed)
            guard case .object = j else { extraError = "Must be a JSON object: { … }"; return }
            profile.extra = j
            extraError = nil
        } catch {
            extraError = "Not valid JSON yet — not saved."
        }
    }

    private func runTest() async {
        test = .running
        let start = Date()
        do {
            let reply = try await client.send(.init(messages: [.user("Reply with the single word OK.")]), via: profile)
            let secs = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))
            let said = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = reply.usage.map { ", \($0.total) tokens" } ?? ""
            test = .passed("Answered \"\(said.prefix(60))\" in \(secs) s\(tokens)")
        } catch {
            test = .failed(String(describing: error))
        }
    }
}

/// "1 request", "2,400 tokens".
func count(_ n: Int, _ noun: String) -> String {
    "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
}

/// Export everything to one file, or load one back (replacing what's here).
struct DataSection: View {
    let model: AppModel
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var opened: Backup.Opened?
    @State private var busy = false
    @State private var message: (text: String, failed: Bool)?

    var body: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                Label("Export data", systemImage: "square.and.arrow.up")
            }
            .disabled(busy)
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .zip,
                          defaultFilename: exportFile?.url.lastPathComponent) { result in
                if let f = exportFile { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
                exportFile = nil
                switch result {
                case .success: message = ("Exported.", false)
                case .failure(let e as CocoaError) where e.code == .userCancelled: break
                case .failure(let e): message = (String(describing: e), true)
                }
            }

            Button {
                importing = true
            } label: {
                Label("Load data", systemImage: "square.and.arrow.down")
            }
            .disabled(busy || model.logger.running)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): Task { await open(url) }
                case .failure(let e): message = (String(describing: e), true)
                }
            }

            if busy { ProgressView() }
            if let message {
                Text(message.text).font(.callout).foregroundStyle(message.failed ? .red : .secondary)
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Export saves your log, foods, photos, recordings and targets in one file, to keep or move to "
                 + "another phone. Models and keys aren't included. Loading a file replaces everything here.")
        }
        .alert("Replace everything on this phone?", isPresented: Binding(get: { opened != nil }, set: { if !$0 { cancel() } }),
               presenting: opened) { o in
            Button("Replace", role: .destructive) { load(o) }
            Button("Cancel", role: .cancel) { cancel() }
        } message: { o in
            Text(summary(o))
        }
    }

    private func export() async {
        busy = true
        defer { busy = false }
        message = nil
        do {
            exportFile = ExportFile(url: try await Backup.export(log: model.log, foods: model.foods, media: try Media.dir()))
            exporting = true
        } catch {
            message = (String(describing: error), true)
        }
    }

    private func open(_ url: URL) async {
        busy = true
        defer { busy = false }
        message = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            opened = try await Backup.open(url)
        } catch {
            message = (String(describing: error), true)
        }
    }

    private func load(_ o: Backup.Opened) {
        opened = nil
        // an entry being worked on would be written into the replaced log
        guard !model.logger.running else {
            Backup.discard(o)
            message = ("An entry is still being logged. Try again when it's done.", true)
            return
        }
        do {
            try Backup.load(o, log: model.log, foods: model.foods, media: try Media.dir())
            message = ("Loaded \(entries(o.log.entries)) "
                       + "and \(count(o.foods, "food")).", false)
            model.logger.kick()
        } catch {
            Backup.discard(o)
            message = ("Nothing was changed: \(error)", true)
        }
    }

    private func cancel() {
        if let o = opened { Backup.discard(o) }
        opened = nil
    }

    private func summary(_ o: Backup.Opened) -> String {
        let here = (try? model.log.summary())?.entries ?? 0
        let span = o.log.first.map { f in o.log.last.map { $0 == f ? " from \(f)" : " from \(f) to \($0)" } ?? "" } ?? ""
        let made = o.manifest.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "The file, exported \(made), has \(entries(o.log.entries))\(span) and \(count(o.foods, "food")). "
            + "It replaces the \(entries(here)) on this phone, with their photos and recordings, your foods, "
            + "and your targets. Your models stay."
    }

    private func entries(_ n: Int) -> String { n == 1 ? "1 entry" : "\(n.formatted()) entries" }
}

/// The finished export, handed to the Files picker.
nonisolated struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    let url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url) }
}
