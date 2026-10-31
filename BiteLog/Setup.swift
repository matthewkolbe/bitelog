import SwiftUI

/// Shown instead of the app while no model is saved: nothing can be logged
/// without one. Starts with what Bite Log is, then connecting a model.
struct SetupView: View {
    let store: ProfileStore
    let client: LLMClient

    var body: some View {
        NavigationStack {
            IntroView {
                NavigationLink {
                    ModelChoice(store: store, client: client)
                } label: {
                    Text("Connect a model").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

/// What Bite Log does, why it needs your own AI model, and what stays private.
/// The first screen of setup, and "How Bite Log works" in Settings.
struct IntroView<Action: View>: View {
    @ViewBuilder var action: () -> Action

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bite Log").font(.largeTitle.bold())
                    Text("A food diary you talk to.").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                point("mic.fill", "Say, type or snap it",
                      "Tell it what you ate, or take a photo. It works out the calories, protein, fat and carbs.")
                point("books.vertical.fill", "Numbers from the USDA",
                      "The AI model reads what you ate. The numbers come from the USDA food database built into the app.")
                point("key.fill", "Bring your own AI model",
                      "There's no Bite Log server or account. Connect a model you choose, like Claude with an "
                      + "API key, or one you run yourself. You pay that provider directly, a few short requests per meal.")
                point("lock.fill", "Private by design",
                      "Your log, photos and recordings stay on this phone and in your own backups, and speech "
                      + "becomes text here too. Only what you log goes to your provider. Your key stays in this "
                      + "iPhone's Keychain. Nothing is sent to us.")
                Text("Bite Log's numbers are estimates and can be wrong. It isn't medical or nutrition advice, "
                     + "and isn't for medical decisions like dosing insulin or managing allergies. "
                     + "Talk to a doctor or dietitian about your health.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    Link("Privacy policy", destination: URL(string: "https://github.com/matthewkolbe/bitelog/blob/main/PRIVACY.md")!)
                    Link("Terms of use", destination: URL(string: "https://github.com/matthewkolbe/bitelog/blob/main/TERMS.md")!)
                }
                .font(.callout)
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            if Action.self != EmptyView.self {
                action().padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            }
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The model presets to start from.
struct ModelChoice: View {
    let store: ProfileStore
    let client: LLMClient

    var body: some View {
        List {
            Section {
                ForEach(Preset.all) { preset in
                    NavigationLink {
                        ConnectView(preset: preset, store: store, client: client)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("A Claude API key is the quickest: make one at console.anthropic.com. "
                     + "You can add more models later in Settings, and the app uses the first one that answers.")
            }
        }
        .navigationTitle("Connect a model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One preset's essentials. Connect sends a test message and saves the model
/// only if it answers.
struct ConnectView: View {
    let store: ProfileStore
    let client: LLMClient
    @State private var profile: Profile
    @State private var key = ""
    @State private var models: [String] = []
    @State private var modelsError: String?
    @State private var connecting = false
    @State private var failure: String?
    @State private var connected = false

    init(preset: Preset, store: ProfileStore, client: LLMClient) {
        self.store = store
        self.client = client
        var p = preset.profile
        p.id = UUID()
        _profile = State(initialValue: p)
    }

    private var anthropic: Bool { profile.kind == .anthropic }

    var body: some View {
        Form {
            Section {
                if !anthropic {
                    TextField("Server address", text: $profile.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField(anthropic ? "API key" : "API key (if the server needs one)", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Connection")
            } footer: {
                Text(anthropic
                     ? "Make a key at console.anthropic.com under API Keys. Setting a monthly spend limit there is wise."
                     : "The address up to and including the version, like http://my-computer.local:8080/v1 "
                       + "or https://openrouter.ai/api/v1.")
            }

            Section {
                TextField("Model id", text: $profile.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !anthropic {
                    Button("Choose from the server's list") { Task { await listModels() } }
                    if !models.isEmpty {
                        Picker("Server's models", selection: $profile.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                            if !models.contains(profile.model) { Text(profile.model).tag(profile.model) }
                        }
                    }
                    if let modelsError { Text(modelsError).foregroundStyle(.red) }
                    Toggle("Reads photos", isOn: $profile.vision)
                }
            } header: {
                Text("Model")
            } footer: {
                if !anthropic { Text("Photo entries need a model that reads photos.") }
            }

            Section {
                Button(connecting ? "Connecting…" : "Connect") { Task { await connect() } }
                    .disabled(connecting || !ready)
                if connecting { ProgressView() }
                if let failure { Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red) }
            } footer: {
                Text("Sends one short test message to check the address, key and model.")
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        // backing out without connecting leaves no key behind
        .onDisappear { if !connected { client.keychain.removeKey(for: profile.id) } }
    }

    private var ready: Bool {
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        return !trimmed(profile.model).isEmpty && URL(string: trimmed(profile.baseURL))?.host() != nil
            && (!anthropic || !trimmed(key).isEmpty)
    }

    private func saveKey() throws {
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespaces)
        profile.model = profile.model.trimmingCharacters(in: .whitespaces)
        try client.keychain.setKey(key, for: profile.id)
    }

    private func listModels() async {
        do {
            try saveKey()
            models = try await client.models(profile)
            modelsError = models.isEmpty ? "The server lists no models." : nil
        } catch {
            modelsError = String(describing: error)
        }
    }

    private func connect() async {
        connecting = true
        failure = nil
        defer { connecting = false }
        do {
            try saveKey()
            _ = try await client.send(.init(messages: [.user("Reply with the single word OK.")]), via: profile)
            connected = true
            store.profiles.append(profile)  // ends setup: the app replaces this screen
        } catch {
            failure = String(describing: error)
        }
    }
}
