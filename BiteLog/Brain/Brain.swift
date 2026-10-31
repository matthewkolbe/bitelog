import Foundation
import Observation

/// The web app's prompts and tool definitions, word for word (brain.json,
/// written by ios/make_brain.py from brain.py and the nutrition server).
nonisolated struct Brain: Decodable {
    let system: String
    let editSystem: String
    let tools: [LLM.Tool]
    let finishHint: String
    let maxRounds: Int
    let recipeSystem: String
    let recipeTools: [LLM.Tool]
    let recipeFinishHint: String
    let recipeRounds: Int
    let labelPrompt: String
    let labelSchema: JSON
    let recipePhotoPrompt: String
    let recipePhotoSchema: JSON

    enum CodingKeys: String, CodingKey {
        case system, editSystem = "edit_system", tools, finishHint = "finish_hint", maxRounds = "max_rounds"
        case recipeSystem = "recipe_system", recipeTools = "recipe_tools", recipeFinishHint = "recipe_finish_hint"
        case recipeRounds = "recipe_rounds", labelPrompt = "label_prompt", labelSchema = "label_schema"
        case recipePhotoPrompt = "recipe_photo_prompt", recipePhotoSchema = "recipe_photo_schema"
    }

    private struct ToolSpec: Decodable {
        let name: String
        let description: String
        let parameters: JSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = try c.decode(String.self, forKey: .system)
        editSystem = try c.decode(String.self, forKey: .editSystem)
        tools = try c.decode([ToolSpec].self, forKey: .tools).map {
            LLM.Tool(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
        finishHint = try c.decode(String.self, forKey: .finishHint)
        maxRounds = try c.decode(Int.self, forKey: .maxRounds)
        recipeSystem = try c.decode(String.self, forKey: .recipeSystem)
        recipeTools = try c.decode([ToolSpec].self, forKey: .recipeTools).map {
            LLM.Tool(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
        recipeFinishHint = try c.decode(String.self, forKey: .recipeFinishHint)
        recipeRounds = try c.decode(Int.self, forKey: .recipeRounds)
        labelPrompt = try c.decode(String.self, forKey: .labelPrompt)
        labelSchema = try c.decode(JSON.self, forKey: .labelSchema)
        recipePhotoPrompt = try c.decode(String.self, forKey: .recipePhotoPrompt)
        recipePhotoSchema = try c.decode(JSON.self, forKey: .recipePhotoSchema)
    }

    static func bundled() throws -> Brain {
        guard let url = Bundle.main.url(forResource: "brain", withExtension: "json") else {
            throw LLM.Failure.notConfigured("brain.json is missing from the app bundle")
        }
        return try JSONDecoder().decode(Brain.self, from: Data(contentsOf: url))
    }
}

/// The model <-> tools loop (brain.py's run_tools). The model asks for tool
/// calls; `handle` runs each one on the phone and returns its result, or
/// `.done` to end the loop.
enum ToolLoop {
    enum Outcome {
        case result(JSON)
        case done
    }

    struct Unfinished: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ start: [LLM.Message], tools: [LLM.Tool], maxRounds: Int, finishHint: String,
                    send: (LLM.Request) async throws -> LLM.Reply,
                    handle: (String, JSON) async throws -> Outcome) async throws {
        var messages = start
        var nudged = false
        for _ in 0..<maxRounds {
            let reply = try await send(LLM.Request(messages: messages, tools: tools))
            messages.append(reply.message)
            if reply.calls.isEmpty {
                if nudged {
                    throw Unfinished(description: "model answered without finishing: \(reply.text.prefix(300))")
                }
                nudged = true
                messages.append(.user(finishHint))
                continue
            }
            for call in reply.calls {
                let result: JSON
                switch try? JSON.parse(call.arguments.isEmpty ? "{}" : call.arguments) {
                case .object(let o)?:
                    switch try await handle(call.name, .object(o)) {
                    case .done: return
                    case .result(let r): result = r
                    }
                case nil:
                    result = ["error": .string("arguments are not valid JSON: \(call.arguments.prefix(200))")]
                default:
                    result = ["error": "arguments must be a JSON object"]
                }
                messages.append(.tool(callID: call.id, content: try result.text()))
            }
        }
        throw Unfinished(description: "model did not finish in \(maxRounds) rounds")
    }
}
