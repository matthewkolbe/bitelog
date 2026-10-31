import Foundation

/// The provider-neutral chat types. Nothing outside the LLM folder knows which
/// provider it is talking to; adapters (`OpenAIChat`, `AnthropicChat`) translate.
/// The app runs every tool call itself: the model only asks for them.
nonisolated enum LLM {
    struct Tool: Equatable, Sendable {
        let name: String
        let description: String
        /// JSON Schema for the arguments.
        let parameters: JSON
    }

    struct ToolCall: Equatable, Sendable {
        let id: String
        let name: String
        /// The arguments as the model wrote them: JSON text, which may be invalid
        /// (the tool loop tells the model so).
        let arguments: String
    }

    enum Part: Equatable, Sendable {
        case text(String)
        case jpeg(Data)
    }

    enum Message: Equatable, Sendable {
        case system(String)
        case user([Part])
        /// `native` is the provider's own form of this turn, sent back to it
        /// unchanged: Anthropic requires its thinking blocks returned as they came.
        case assistant(text: String, calls: [ToolCall], native: JSON?)
        case tool(callID: String, content: String)

        static func user(_ text: String) -> Message { .user([.text(text)]) }
    }

    struct Request: Equatable, Sendable {
        var messages: [Message]
        var tools: [Tool] = []
        /// Anthropic requires a cap; OpenAI-compatible servers get none (their
        /// field names differ, and their defaults are the model's own limit).
        var maxTokens = 16000
        /// The reply must be JSON matching this schema (structured output).
        var jsonSchema: (name: String, schema: JSON)?

        static func == (a: Request, b: Request) -> Bool {
            a.messages == b.messages && a.tools == b.tools && a.maxTokens == b.maxTokens
                && a.jsonSchema?.name == b.jsonSchema?.name && a.jsonSchema?.schema == b.jsonSchema?.schema
        }
    }

    struct Usage: Equatable, Sendable, Codable {
        var input = 0
        var output = 0
        var total: Int { input + output }
    }

    struct Reply: Equatable, Sendable {
        var text: String
        var calls: [ToolCall]
        var native: JSON?
        /// nil when the server doesn't report it.
        var usage: Usage?

        var message: Message { .assistant(text: text, calls: calls, native: native) }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notConfigured(String)
        /// The provider answered with an error: status and its message.
        case http(Int, String)
        /// Still busy (409/429/529) after waiting as long as the server asked.
        case busy(String)
        case badReply(String)
        /// Anthropic's safety classifiers declined the request.
        case refused(String)
        /// The reply hit the output cap before finishing.
        case truncated
        case overLimit(String)
        /// No profile in the route can take the entry; one reason per profile.
        case noRoute([String])

        var description: String {
            switch self {
            case .notConfigured(let m), .badReply(let m), .overLimit(let m): m
            case .http(let status, let m): "HTTP \(status): \(m)"
            case .busy(let m): "still busy: \(m)"
            case .refused(let m): "the model declined: \(m)"
            case .truncated: "the reply was cut off at its length limit"
            case .noRoute(let reasons): "no model available — " + reasons.joined(separator: "; ")
            }
        }
    }
}
