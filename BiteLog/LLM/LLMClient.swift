import Foundation
import Observation

/// Sends requests for a profile: its key, its limits, and the waits its server
/// asks for. Also checks reachability and picks a profile for an entry (the route).
@Observable
final class LLMClient {
    let keychain: Keychain
    let limiter: Limiter
    @ObservationIgnored let session: URLSession
    /// Injected so tests don't sleep.
    @ObservationIgnored var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The longest a request waits out "busy" answers before failing.
    @ObservationIgnored var maxWait: Duration = .seconds(600)

    init(keychain: Keychain = Keychain(), limiter: Limiter = Limiter(), session: URLSession = .shared) {
        self.keychain = keychain
        self.limiter = limiter
        self.session = session
    }

    func key(for p: Profile) throws -> String? { try keychain.key(for: p.id) }

    /// One chat request. `onWait(true)` while waiting on the server or a
    /// per-minute limit, `onWait(false)` when that ends.
    func send(_ req: LLM.Request, via p: Profile, onWait: (Bool) -> Void = { _ in }) async throws -> LLM.Reply {
        guard !p.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLM.Failure.notConfigured("\(p.name) has no model set")
        }
        if let over = limiter.overDailyLimit(p) { throw LLM.Failure.overLimit(over) }
        try await limiter.takeSlot(p, sleep: sleep, onWait: onWait)
        let request = try p.kind.adapter.chatRequest(req, profile: p, key: key(for: p))
        let reply = try p.kind.adapter.reply(from: try await perform(request, onWait: onWait))
        if p.limits.tokensPerDay != nil && reply.usage == nil {
            throw LLM.Failure.badReply("\(p.name)'s server doesn't report token usage, so its daily token "
                                       + "limit can't be kept; remove the limit to use it")
        }
        limiter.record(p, usage: reply.usage)
        return reply
    }

    /// The model ids the server offers.
    func models(_ p: Profile) async throws -> [String] {
        try Adapters.models(from: await perform(p.kind.adapter.modelsRequest(profile: p, key: key(for: p)),
                                                onWait: { _ in }, waits: false))
    }

    /// nil when the profile's server answers its model list within `timeout`;
    /// otherwise why not.
    func unreachable(_ p: Profile, timeout: TimeInterval = 3) async -> String? {
        do {
            var r = try p.kind.adapter.modelsRequest(profile: p, key: key(for: p))
            r.timeoutInterval = timeout
            _ = try await perform(r, onWait: { _ in }, waits: false)
            return nil
        } catch let e as URLError where e.code == .timedOut {
            return "no answer in \(Int(timeout)) s"
        } catch let e as URLError {
            return e.localizedDescription
        } catch {
            return String(describing: error)
        }
    }

    /// The profile an entry uses: the first enabled one, in the user's order,
    /// that has what the entry needs, is under its daily limit, and answers.
    /// Chosen once, before the entry starts; an error during the entry is shown
    /// as an error, never sent on to the next profile.
    func route(_ profiles: [Profile], needsVision: Bool) async throws -> Profile {
        var reasons: [String] = []
        for p in profiles where p.enabled {
            if needsVision && !p.vision {
                reasons.append("\(p.name): can't read photos")
            } else if let over = limiter.overDailyLimit(p) {
                reasons.append(over)
            } else if let why = await unreachable(p) {
                reasons.append("\(p.name): \(why)")
            } else {
                return p
            }
        }
        throw LLM.Failure.noRoute(reasons.isEmpty ? ["none set up in Settings"] : reasons)
    }

    /// Performs a request. 409 (our gateway: another model is loaded or a swap
    /// is pending), 429 (rate limited) and 529 (Anthropic overloaded) mean "come
    /// back later": wait as long as Retry-After says, up to `maxWait` in all.
    private func perform(_ request: URLRequest, onWait: (Bool) -> Void, waits: Bool = true) async throws -> Data {
        var waited = Duration.zero
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLM.Failure.badReply("not an HTTP response") }
            if (200..<300).contains(http.statusCode) { return data }
            let message = Adapters.errorMessage(data)
            guard waits, [409, 429, 529].contains(http.statusCode) else {
                throw LLM.Failure.http(http.statusCode, message)
            }
            let delay = Duration.seconds(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 15)
            guard waited + delay <= maxWait else { throw LLM.Failure.busy(message) }
            onWait(true)
            try await sleep(delay)
            onWait(false)
            waited += delay
        }
    }
}

/// Per-profile limits: requests per minute (by waiting) and tokens per day
/// (by skipping the profile until tomorrow). Today's usage is kept across
/// launches; the last minute's requests only in memory.
@Observable
final class Limiter {
    struct Day: Codable, Equatable {
        var day: String
        var requests = 0
        var tokens = 0
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var recent: [UUID: [Date]] = [:]
    private var days: [UUID: Day]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        days = (defaults.data(forKey: "llm.usage")).flatMap { try? JSONDecoder().decode([UUID: Day].self, from: $0) } ?? [:]
    }

    /// Today's usage (local calendar day).
    func today(_ p: Profile) -> Day {
        let key = Self.dayKey(now())
        return days[p.id].flatMap { $0.day == key ? $0 : nil } ?? Day(day: key)
    }

    func overDailyLimit(_ p: Profile) -> String? {
        guard let cap = p.limits.tokensPerDay, today(p).tokens >= cap else { return nil }
        return "\(p.name): reached today's limit of \(cap.formatted()) tokens"
    }

    /// Waits until a request fits the per-minute limit, then counts it.
    func takeSlot(_ p: Profile, sleep: (Duration) async throws -> Void, onWait: (Bool) -> Void) async throws {
        if let rpm = p.limits.requestsPerMinute, rpm > 0 {
            while true {
                let cutoff = now().addingTimeInterval(-60)
                let times = (recent[p.id] ?? []).filter { $0 > cutoff }
                recent[p.id] = times
                guard times.count >= rpm, let oldest = times.first else { break }
                onWait(true)
                try await sleep(.seconds(oldest.timeIntervalSince(cutoff)))
                onWait(false)
            }
        }
        recent[p.id, default: []].append(now())
    }

    func record(_ p: Profile, usage: LLM.Usage?) {
        var d = today(p)
        d.requests += 1
        d.tokens += usage?.total ?? 0
        days[p.id] = d
        if let data = try? JSONEncoder().encode(days) { defaults.set(data, forKey: "llm.usage") }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
