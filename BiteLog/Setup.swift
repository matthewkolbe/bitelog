import SwiftUI

/// Shown instead of the app while no model is saved: nothing can be logged
/// without one, so connecting a model comes first.
struct SetupView: View {
    let store: ProfileStore
    let client: LLMClient

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Bite Log uses an AI model to read what you ate. Connect one to start.")
                }
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
                } header: {
                    Text("Connect a model")
                } footer: {
                    Text("A Claude API key is the quickest. Keys stay on this phone. "
                         + "You can add more models later in Settings.")
                }
            }
            .navigationTitle("Welcome")
        }
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
