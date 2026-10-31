import Foundation
import Testing
@testable import BiteLog

/// The LLM layer against canned HTTP: what each adapter sends, how replies are
/// read, the waits, the limits and the route. Serialized: they share the fake
/// network's handler.
@MainActor
@Suite(.serialized)
struct LLMTests {
    let tools = [LLM.Tool(name: "search_foods", description: "find foods",
                          parameters: ["type": "object", "properties": ["query": ["type": "string"]]])]
    let qwen = Profile(name: "Home", kind: .openAI, baseURL: "http://home.test:8080/v1", model: "qwen38",
                       vision: true, extra: ["temperature": 0.6, "chat_template_kwargs": ["enable_thinking": false]])
    let claude = Profile(name: "Claude", kind: .anthropic, baseURL: "https://api.anthropic.test/v1",
                         model: "claude-haiku-5-5", vision: true)

    func client(_ handler: @escaping FakeNet.Handler) -> (LLMClient, Recorder) {
        FakeNet.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeNet.self]
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let c = LLMClient(keychain: Keychain(service: "test-\(UUID())"), limiter: Limiter(defaults: defaults),
                          session: URLSession(configuration: config))
        let rec = Recorder()
        c.sleep = { rec.sleeps.append($0) }
        return (c, rec)
    }

    // MARK: - OpenAI-compatible

    @Test func openAIRequest() throws {
        let photo = Data([0xFF, 0xD8, 0xFF])
        let req = LLM.Request(messages: [
            .system("You log food."),
            .user([.text("this"), .jpeg(photo)]),
            .assistant(text: "", calls: [.init(id: "c1", name: "search_foods", arguments: #"{"query":"egg"}"#)], native: nil),
            .tool(callID: "c1", content: #"[{"fdc_id":1}]"#),
        ], tools: tools)
        let r = try OpenAIChat.chatRequest(req, profile: qwen, key: "sk-1")
        #expect(r.url?.absoluteString == "http://home.test:8080/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let body = try JSON.parse(r.httpBody!)
        #expect(body["model"] == "qwen38")
        #expect(body["temperature"] == 0.6)
        #expect(body["chat_template_kwargs"]?["enable_thinking"] == false)
        #expect(body["max_tokens"] == nil)
        #expect(body["tools"]?.array?.first?["function"]?["name"] == "search_foods")
        let m = try #require(body["messages"]?.array)
        #expect(m[0] == ["role": "system", "content": "You log food."])
        #expect(m[1]["content"]?.array?[1]["image_url"]?["url"] == .string("data:image/jpeg;base64,/9j/"))
        #expect(m[2]["tool_calls"]?.array?.first?["function"]?["arguments"] == #"{"query":"egg"}"#)
        #expect(m[3] == ["role": "tool", "tool_call_id": "c1", "content": #"[{"fdc_id":1}]"#])
    }

    @Test func openAIReply() throws {
        let reply = try OpenAIChat.reply(from: Data(#"""
            {"choices":[{"finish_reason":"tool_calls","message":{"content":null,"tool_calls":[
              {"id":"c9","type":"function","function":{"name":"lookup","arguments":"{\"food\":\"grapes\"}"}}]}}],
             "usage":{"prompt_tokens":1200,"completion_tokens":40}}
            """#.utf8))
        #expect(reply.text == "")
        #expect(reply.calls == [.init(id: "c9", name: "lookup", arguments: #"{"food":"grapes"}"#)])
        #expect(reply.usage == .init(input: 1200, output: 40))
        #expect(throws: LLM.Failure.truncated) {
            try OpenAIChat.reply(from: Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Let me"}}]}"#.utf8))
        }
    }

    // MARK: - Anthropic

    @Test func anthropicRequest() throws {
        let native: JSON = [["type": "thinking", "thinking": "", "signature": "sig"],
                            ["type": "tool_use", "id": "t1", "name": "search_foods", "input": ["query": "egg"]]]
        let req = LLM.Request(messages: [
            .system("You log food."),
            .user("two eggs"),
            .assistant(text: "", calls: [], native: native),
            .tool(callID: "t1", content: "a"),
            .tool(callID: "t2", content: "b"),
            .user("Finish by calling log_food."),
        ], tools: tools)
        let r = try AnthropicChat.chatRequest(req, profile: claude, key: "sk-ant")
        #expect(r.url?.absoluteString == "https://api.anthropic.test/v1/messages")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try JSON.parse(r.httpBody!)
        #expect(body["system"] == "You log food.")
        #expect(body["max_tokens"] == 16000)
        #expect(body["temperature"] == nil)
        #expect(body["tools"]?.array?.first?["input_schema"]?["type"] == "object")
        let m = try #require(body["messages"]?.array)
        #expect(m.map { $0["role"]?.string } == ["user", "assistant", "user"])
        #expect(m[1]["content"] == native)  // thinking block returned exactly as it came
        let results = try #require(m[2]["content"]?.array)
        #expect(results.map { $0["type"]?.string } == ["tool_result", "tool_result", "text"])
        #expect(results[1]["tool_use_id"] == "t2")
        #expect(throws: LLM.Failure.notConfigured("Anthropic needs an API key")) {
            try AnthropicChat.chatRequest(req, profile: claude, key: nil)
        }
    }

    @Test func anthropicReply() throws {
        let reply = try AnthropicChat.reply(from: Data(#"""
            {"stop_reason":"tool_use","content":[
              {"type":"thinking","thinking":"","signature":"s"},
              {"type":"text","text":"Looking up."},
              {"type":"tool_use","id":"t1","name":"lookup","input":{"food":"grapes","grams":130}}],
             "usage":{"input_tokens":100,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":50}}
            """#.utf8))
        #expect(reply.text == "Looking up.")
        #expect(reply.calls.map(\.name) == ["lookup"])
        #expect(try JSON.parse(reply.calls[0].arguments) == ["food": "grapes", "grams": 130])
        #expect(reply.usage == .init(input: 2100, output: 50))
        #expect(reply.native?.array?.count == 3)
        #expect(throws: LLM.Failure.refused("cyber")) {
            try AnthropicChat.reply(from: Data(#"{"stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[]}"#.utf8))
        }
    }

    // MARK: - sending

    @Test func waitsOutBusyAnswers() async throws {
        var calls = 0
        let (c, rec) = client { req in
            calls += 1
            if calls < 3 { return (409, ["Retry-After": "30"], Data(#"{"detail":"qwen36 is loaded"}"#.utf8)) }
            return (200, [:], Data(#"{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":5,"completion_tokens":1}}"#.utf8))
        }
        var waits: [Bool] = []
        let reply = try await c.send(.init(messages: [.user("hi")]), via: qwen) { waits.append($0) }
        #expect(reply.text == "OK")
        #expect(rec.sleeps == [.seconds(30), .seconds(30)])
        #expect(waits == [true, false, true, false])
        #expect(c.limiter.today(qwen) == .init(day: Limiter.dayKey(Date()), requests: 1, tokens: 6))
    }

    @Test func busyTooLongFails() async throws {
        let (c, _) = client { _ in (429, ["Retry-After": "400"], Data(#"{"error":{"message":"slow down"}}"#.utf8)) }
        try c.keychain.setKey("k", for: claude.id)
        await #expect(throws: LLM.Failure.busy("slow down")) {
            try await c.send(.init(messages: [.user("hi")]), via: claude)
        }
    }

    @Test func otherErrorsCarryTheProvidersMessage() async throws {
        let (c, _) = client { _ in (400, [:], Data(#"{"error":{"message":"model not found"}}"#.utf8)) }
        await #expect(throws: LLM.Failure.http(400, "model not found")) {
            try await c.send(.init(messages: [.user("hi")]), via: qwen)
        }
    }

    // MARK: - limits

    @Test func perMinuteLimitWaits() async throws {
        let (c, rec) = client { _ in (200, [:], Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)) }
        var p = qwen
        p.limits.requestsPerMinute = 2
        var clock = Date(timeIntervalSince1970: 1_000_000)
        c.limiter.now = { clock }
        c.sleep = { d in rec.sleeps.append(d); clock += Double(d.components.seconds) }
        for _ in 0..<3 {
            _ = try await c.send(.init(messages: [.user("hi")]), via: p)
            clock += 10
        }
        // third request at +20 s waits until the first is a minute old
        #expect(rec.sleeps == [.seconds(40)])
    }

    @Test func dailyLimitStopsAndRouteSkips() async throws {
        let (c, _) = client { req in
            if req.url?.path.hasSuffix("/models") == true { return (200, [:], Data(#"{"data":[{"id":"m"}]}"#.utf8)) }
            return (200, [:], Data(#"{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":900,"completion_tokens":200}}"#.utf8))
        }
        var capped = qwen
        capped.limits.tokensPerDay = 1000
        var backup = qwen
        backup.id = UUID()
        backup.name = "Backup"
        _ = try await c.send(.init(messages: [.user("hi")]), via: capped)  // 1,100 tokens: now over
        await #expect(throws: LLM.Failure.overLimit("Home: reached today's limit of 1,000 tokens")) {
            try await c.send(.init(messages: [.user("hi")]), via: capped)
        }
        #expect(try await c.route([capped, backup], needsVision: false).name == "Backup")
    }

    @Test func dailyLimitNeedsUsage() async throws {
        let (c, _) = client { _ in (200, [:], Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)) }
        var p = qwen
        p.limits.tokensPerDay = 1000
        await #expect(throws: LLM.Failure.self) { try await c.send(.init(messages: [.user("hi")]), via: p) }
    }

    // MARK: - route

    @Test func routeTakesFirstThatCanAndAnswers() async throws {
        let (c, _) = client { req in
            req.url?.host == "down.test" ? (503, [:], Data(#"{"detail":"loading"}"#.utf8))
                                         : (200, [:], Data(#"{"data":[]}"#.utf8))
        }
        var down = qwen
        down.name = "Down"
        down.baseURL = "http://down.test/v1"
        var blind = qwen
        blind.name = "Blind"
        blind.vision = false
        var off = qwen
        off.name = "Off"
        off.enabled = false
        var up = qwen
        up.name = "Up"
        #expect(try await c.route([off, down, blind, up], needsVision: true).name == "Up")
        #expect(try await c.route([blind, up], needsVision: false).name == "Blind")
        await #expect(throws: LLM.Failure.noRoute(["Down: HTTP 503: loading", "Blind: can't read photos"])) {
            try await c.route([down, blind], needsVision: true)
        }
    }

    // MARK: - storage

    @Test func keychainRoundTrip() throws {
        let k = Keychain(service: "test-\(UUID())")
        let id = UUID()
        #expect(try k.key(for: id) == nil)
        try k.setKey(" sk-1 \n", for: id)
        #expect(try k.key(for: id) == "sk-1")
        try k.setKey("sk-2", for: id)
        #expect(try k.key(for: id) == "sk-2")
        try k.setKey("", for: id)
        #expect(try k.key(for: id) == nil)
    }

    @Test func profilesPersistAndACorruptFileIsAnError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        let store = try ProfileStore(file: file)
        store.profiles = [qwen, claude]
        #expect(try ProfileStore(file: file).profiles == [qwen, claude])
        try Data("{not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try ProfileStore(file: file) }
    }

    // MARK: - live

    /// Against the real gateway, only when asked:
    /// TEST_RUNNER_BITELOG_LIVE=http://<server>:<port>/v1 xcodebuild … test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITELOG_LIVE"] != nil))
    func liveGateway() async throws {
        var p = qwen
        p.baseURL = ProcessInfo.processInfo.environment["BITELOG_LIVE"]!
        let c = LLMClient(keychain: Keychain(service: "test-\(UUID())"),
                          limiter: Limiter(defaults: UserDefaults(suiteName: "test-\(UUID())")!))
        #expect(await c.unreachable(p) == nil)
        let reply = try await c.send(.init(messages: [.user("Call search_foods for grapes.")], tools: tools), via: p)
        #expect(reply.calls.first?.name == "search_foods")
        #expect(reply.usage != nil)
    }
}

final class Recorder {
    var sleeps: [Duration] = []
}

/// A URLProtocol that answers from `handler` instead of the network.
nonisolated final class FakeNet: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, [String: String], Data)
    nonisolated(unsafe) static var handler: Handler = { _ in (500, [:], Data()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, headers, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
