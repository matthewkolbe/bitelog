import Foundation
import Observation
import Security

/// One configured model endpoint. The API key is not here: it lives in the
/// Keychain under the profile's id.
nonisolated struct Profile: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Chat Completions: OpenAI, OpenRouter, Gemini's compatible endpoint,
        /// Groq, Ollama, LM Studio, llama.cpp, our gateway.
        case openAI
        /// Anthropic Messages.
        case anthropic

        var title: String {
            switch self {
            case .openAI: "OpenAI-compatible"
            case .anthropic: "Anthropic"
            }
        }
    }

    /// Spending guards, enforced on the phone before each request.
    struct Limits: Codable, Equatable, Sendable {
        /// Requests over this in a minute wait for the minute to pass.
        var requestsPerMinute: Int?
        /// At this many tokens (input + output) today, the route skips this profile
        /// until tomorrow.
        var tokensPerDay: Int?
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// Up to and including the version, e.g. https://api.anthropic.com/v1.
    var baseURL: String
    var model: String
    /// Whether the model reads images; photo entries skip profiles without it.
    var vision: Bool
    var enabled = true
    var limits = Limits()
    /// Added to every request body as-is: sampling settings, template flags.
    var extra: JSON = [:]

    func url(_ path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? base + path : base + "/" + path),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw LLM.Failure.notConfigured("\(name): the server address \"\(baseURL)\" isn't a web address")
        }
        return url
    }
}

/// Starting points for a new profile.
nonisolated struct Preset: Identifiable, Sendable {
    let title: String
    let detail: String
    let profile: Profile
    var id: String { title }

    static let all: [Preset] = [
        Preset(title: "Anthropic (Claude)", detail: "Needs an API key from console.anthropic.com",
               profile: Profile(name: "Claude Haiku", kind: .anthropic, baseURL: "https://api.anthropic.com/v1",
                                model: "claude-haiku-5-5", vision: true,
                                limits: .init(requestsPerMinute: 30, tokensPerDay: 2_000_000))),
        Preset(title: "Qwen on your own server", detail: "llama.cpp or a gateway in front of it, on your network",
               profile: Profile(name: "My Qwen", kind: .openAI, baseURL: "http://my-computer.local:8080/v1",
                                model: "", vision: true,
                                // Qwen's settings for precise work, thinking off
                                extra: ["temperature": 0.6, "top_p": 0.95, "top_k": 20,
                                        "chat_template_kwargs": ["enable_thinking": false]])),
        Preset(title: "Other OpenAI-compatible", detail: "OpenAI, OpenRouter, Ollama, LM Studio, …",
               profile: Profile(name: "Model", kind: .openAI, baseURL: "https://", model: "", vision: false)),
    ]
}

/// The user's profiles, in route order: each entry tries them top to bottom.
@Observable
final class ProfileStore {
    var profiles: [Profile] {
        didSet { save() }
    }
    private let file: URL
    /// The last save's failure, shown in settings.
    private(set) var saveError: String?

    /// A file that exists but doesn't decode is an error, not an empty list: the
    /// next save would overwrite the user's profiles.
    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: file))
        } else {
            profiles = []
        }
    }

    static func app() throws -> ProfileStore {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let file = dir.appendingPathComponent(AppFiles.name("profiles", "json"))
        return try ProfileStore(file: file)
    }

    private func save() {
        do {
            try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Couldn't save the model list: \(error.localizedDescription)"
        }
    }
}

/// API keys, one per profile, in the Keychain (this device only, never synced
/// or backed up in the clear).
struct Keychain {
    var service = "app.bitelog.ios.llm"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "Keychain error \(status): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")
        }
    }

    func key(for id: UUID) throws -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query(id).merging([kSecReturnData as String: true,
                                                            kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
                                         as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// An empty key removes it.
    func setKey(_ key: String, for id: UUID) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query(id) as CFDictionary)
        guard !key.isEmpty else { return }
        let status = SecItemAdd(query(id).merging([
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func removeKey(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}
