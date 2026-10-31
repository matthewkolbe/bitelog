import Foundation

/// How to talk to one kind of API: build its requests, read its replies.
nonisolated protocol ChatAdapter {
    static func chatRequest(_ req: LLM.Request, profile: Profile, key: String?) throws -> URLRequest
    static func reply(from data: Data) throws -> LLM.Reply
    static func modelsRequest(profile: Profile, key: String?) throws -> URLRequest
}

nonisolated extension Profile.Kind {
    var adapter: any ChatAdapter.Type {
        switch self {
        case .openAI: OpenAIChat.self
        case .anthropic: AnthropicChat.self
        }
    }
}

nonisolated enum Adapters {
    /// Model ids from a `GET /models` reply; both APIs answer `{data: [{id}]}`.
    static func models(from data: Data) throws -> [String] {
        guard let list = try JSON.parse(data)["data"]?.array else {
            throw LLM.Failure.badReply("the model list has no data array")
        }
        return list.compactMap { $0["id"]?.string }.sorted()
    }

    /// The provider's own error message: `{error: {message}}` (OpenAI, Anthropic),
    /// `{detail}` (FastAPI servers like our gateway), else the body's start.
    static func errorMessage(_ data: Data) -> String {
        if let j = try? JSON.parse(data) {
            if let m = j["error"]?["message"]?.string ?? j["error"]?.string { return m }
            if let d = j["detail"] { return d.string ?? ((try? d.text()) ?? "") }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no message" : text
    }

    static func post(_ url: URL, body: JSON, headers: [String: String]) throws -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 600)  // a long tool round on a local model takes minutes
        r.httpMethod = "POST"
        r.httpBody = try body.data()
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    static func get(_ url: URL, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}

// MARK: - OpenAI Chat Completions

nonisolated enum OpenAIChat: ChatAdapter {
    static func headers(_ key: String?) -> [String: String] {
        guard let key, !key.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(key)"]
    }

    static func chatRequest(_ req: LLM.Request, profile: Profile, key: String?) throws -> URLRequest {
        var body: JSON = ["model": .string(profile.model), "messages": .array(req.messages.map(message))]
        if !req.tools.isEmpty {
            body = body.merging(["tools": .array(req.tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description),
                                                  "parameters": $0.parameters]]
            })])
        }
        body = body.merging(profile.extra)
        if let (name, schema) = req.jsonSchema {
            // a structured read (a label's numbers) samples greedily, as brain.py's read_label does
            body = body.merging(["response_format": ["type": "json_schema", "json_schema": ["name": .string(name), "schema": schema]],
                                 "temperature": 0])
        }
        return try Adapters.post(profile.url("chat/completions"), body: body, headers: headers(key))
    }

    static func message(_ m: LLM.Message) -> JSON {
        switch m {
        case .system(let s):
            return ["role": "system", "content": .string(s)]
        case .user(let parts):
            if case .text(let t)? = parts.first, parts.count == 1 {
                return ["role": "user", "content": .string(t)]
            }
            return ["role": "user", "content": .array(parts.map {
                switch $0 {
                case .text(let t): ["type": "text", "text": .string(t)]
                case .jpeg(let d): ["type": "image_url",
                                    "image_url": ["url": .string("data:image/jpeg;base64,\(d.base64EncodedString())")]]
                }
            })]
        case .assistant(let text, let calls, _):
            var out: JSON = ["role": "assistant", "content": .string(text)]
            if !calls.isEmpty {
                out = out.merging(["tool_calls": .array(calls.map {
                    ["id": .string($0.id), "type": "function",
                     "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
                })])
            }
            return out
        case .tool(let id, let content):
            return ["role": "tool", "tool_call_id": .string(id), "content": .string(content)]
        }
    }

    static func reply(from data: Data) throws -> LLM.Reply {
        let j = try JSON.parse(data)
        guard let choice = j["choices"]?.array?.first, let msg = choice["message"] else {
            throw LLM.Failure.badReply("the reply has no choices[0].message")
        }
        let calls = try (msg["tool_calls"]?.array ?? []).map { c -> LLM.ToolCall in
            guard let id = c["id"]?.string, let name = c["function"]?["name"]?.string else {
                throw LLM.Failure.badReply("a tool call has no id or function name")
            }
            // some servers send arguments as an object instead of JSON text
            let args = c["function"]?["arguments"]
            return LLM.ToolCall(id: id, name: name, arguments: try args?.string ?? args.map { try $0.text() } ?? "{}")
        }
        if choice["finish_reason"]?.string == "length" && calls.isEmpty { throw LLM.Failure.truncated }
        let usage = j["usage"].flatMap { u -> LLM.Usage? in
            guard let i = u["prompt_tokens"]?.int, let o = u["completion_tokens"]?.int else { return nil }
            return LLM.Usage(input: i, output: o)
        }
        return LLM.Reply(text: msg["content"]?.string ?? "", calls: calls, native: nil, usage: usage)
    }

    static func modelsRequest(profile: Profile, key: String?) throws -> URLRequest {
        Adapters.get(try profile.url("models"), headers: headers(key))
    }
}

// MARK: - Anthropic Messages

nonisolated enum AnthropicChat: ChatAdapter {
    static let version = "2026-10-21"

    static func headers(_ key: String?) throws -> [String: String] {
        guard let key, !key.isEmpty else { throw LLM.Failure.notConfigured("Anthropic needs an API key") }
        return ["x-api-key": key, "anthropic-version": version]
    }

    static func chatRequest(_ req: LLM.Request, profile: Profile, key: String?) throws -> URLRequest {
        let system = req.messages.compactMap { if case .system(let s) = $0 { s } else { nil } }
        var body: JSON = [
            "model": .string(profile.model), "max_tokens": .number(Double(req.maxTokens)),
            "messages": .array(try turns(req.messages)),
            // caches the stable prefix (tools, system) across a tool loop's rounds
            "cache_control": ["type": "ephemeral"],
        ]
        if !system.isEmpty { body = body.merging(["system": .string(system.joined(separator: "\n\n"))]) }
        if !req.tools.isEmpty {
            body = body.merging(["tools": .array(req.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters]
            })])
        }
        if let (_, schema) = req.jsonSchema {
            body = body.merging(["output_config": ["format": ["type": "json_schema", "schema": schema]]])
        }
        return try Adapters.post(profile.url("messages"), body: body.merging(profile.extra), headers: headers(key))
    }

    /// The conversation as alternating user/assistant turns: tool results are
    /// user content, and adjacent turns of one role become one turn (all of a
    /// round's tool results must come back in a single user message).
    static func turns(_ messages: [LLM.Message]) throws -> [JSON] {
        var out: [(role: String, content: [JSON])] = []
        func add(_ role: String, _ blocks: [JSON]) {
            if out.last?.role == role { out[out.count - 1].content += blocks } else { out.append((role, blocks)) }
        }
        for m in messages {
            switch m {
            case .system:
                continue
            case .user(let parts):
                add("user", parts.map {
                    switch $0 {
                    case .text(let t): ["type": "text", "text": .string(t)]
                    case .jpeg(let d): ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                                     "data": .string(d.base64EncodedString())]]
                    }
                })
            case .assistant(let text, let calls, let native):
                if let blocks = native?.array {
                    add("assistant", blocks)
                } else {
                    let textBlock: [JSON] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
                    add("assistant", try textBlock + calls.map {
                        ["type": "tool_use", "id": .string($0.id), "name": .string($0.name),
                         "input": try JSON.parse($0.arguments)]
                    })
                }
            case .tool(let id, let content):
                add("user", [["type": "tool_result", "tool_use_id": .string(id), "content": .string(content)]])
            }
        }
        return out.map { ["role": .string($0.role), "content": .array($0.content)] }
    }

    static func reply(from data: Data) throws -> LLM.Reply {
        let j = try JSON.parse(data)
        guard let content = j["content"]?.array else { throw LLM.Failure.badReply("the reply has no content") }
        switch j["stop_reason"]?.string {
        case "refusal":
            let d = j["stop_details"]
            throw LLM.Failure.refused(d?["explanation"]?.string ?? d?["category"]?.string ?? "no reason given")
        case "max_tokens":
            throw LLM.Failure.truncated
        default:
            break
        }
        var text = ""
        var calls: [LLM.ToolCall] = []
        for b in content {
            switch b["type"]?.string {
            case "text": text += b["text"]?.string ?? ""
            case "tool_use":
                guard let id = b["id"]?.string, let name = b["name"]?.string else {
                    throw LLM.Failure.badReply("a tool_use block has no id or name")
                }
                calls.append(.init(id: id, name: name, arguments: try (b["input"] ?? [:]).text()))
            default: break  // thinking blocks: kept in native, sent back as they came
            }
        }
        let u = j["usage"]
        let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + (u?[$1]?.int ?? 0) }
        return LLM.Reply(text: text, calls: calls, native: .array(content),
                         usage: u.map { _ in LLM.Usage(input: input, output: u?["output_tokens"]?.int ?? 0) })
    }

    static func modelsRequest(profile: Profile, key: String?) throws -> URLRequest {
        Adapters.get(try profile.url("models"), headers: try headers(key))
    }
}
