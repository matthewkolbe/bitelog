import SwiftUI

/// Step-by-step help for connecting a model: getting a key, or running one at
/// home. Opened from a preset's connect screen and from Settings.
nonisolated enum Guide: String, CaseIterable, Identifiable, Sendable {
    case claude, openAI, openRouter, ownComputer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .openAI: "OpenAI (GPT)"
        case .openRouter: "OpenRouter, free"
        case .ownComputer: "Your own computer"
        }
    }

    var summary: String {
        switch self {
        case .claude: "A few cents a day, reliable, reads photos"
        case .openAI: "A few cents a day, reads photos"
        case .openRouter: "Free, about 10 entries a day"
        case .ownComputer: "The most private: nothing leaves your home. Free"
        }
    }
}

struct GuideList: View {
    var body: some View {
        List(Guide.allCases) { g in
            NavigationLink { GuideView(guide: g) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title)
                    Text(g.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Model guides")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GuideView: View {
    let guide: Guide
    /// The last thing copied, to say so on its button.
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch guide {
                case .claude: claude
                case .openAI: openAI
                case .openRouter: openRouter
                case .ownComputer: ownComputer
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(guide.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Claude

    @ViewBuilder private var claude: some View {
        para("Claude Haiku is fast, reads photos, and handles Bite Log's food lookups reliably. You pay Anthropic for what you use, from credit you buy ahead.")
        step(1, "Make an account at **console.anthropic.com**. This is Anthropic's developer console: a Claude.ai subscription doesn't include it.")
        step(2, "Under **Billing**, buy a little credit. $5 lasts a long time.")
        step(3, "Cap the spending: in **Settings → Workspaces**, create a workspace called Bite Log, open its **Limits**, and set a monthly spend limit, like $5. Keys in that workspace stop working at the limit, and your other keys aren't affected.")
        step(4, "In **API Keys**, choose **Create Key**, pick the Bite Log workspace, and copy the key. It's shown only once.")
        step(5, "In Bite Log, choose **Anthropic (Claude)**, paste the key, and tap **Connect**.")
        heading("What it costs")
        para("Claude Haiku 5.5 is $0.10 per million tokens read and $0.50 per million written. An entry is a few short requests, roughly a third of a cent, so about $1 a month at 10 entries a day. That's an estimate: photos and long entries cost more.")
        heading("Privacy")
        para("What you log goes to Anthropic under its API terms, which say it doesn't train its models on API data. Your key stays in this iPhone's Keychain.")
    }

    // MARK: - OpenAI

    @ViewBuilder private var openAI: some View {
        para("OpenAI's GPT-6 Luna is its fast, low-cost model, and reads photos. You pay OpenAI for what you use, from credit you buy ahead.")
        step(1, "Make an account at **platform.openai.com**. This is OpenAI's developer platform: a ChatGPT subscription doesn't include it.")
        step(2, "Under **Billing**, buy a little credit. $5 lasts a long time.")
        step(3, "Cap the spending: create a project called Bite Log, then in **Project settings → Limits** set a monthly spend limit, like $5, and make it a hard limit so requests stop at it.")
        step(4, "In **API keys**, create a key in the Bite Log project and copy it. It's shown only once.")
        step(5, "In Bite Log, choose **OpenAI (GPT)**, paste the key, and tap **Connect**.")
        heading("What it costs")
        para("GPT-6 Luna is $0.10 per million tokens read and $0.50 per million written, the same as Claude Haiku: roughly a third of a cent an entry, about $1 a month at 10 entries a day. That's an estimate.")
        para("Bite Log turns Luna's reasoning off: OpenAI allows tool calls through the API the app uses only without it.")
        heading("Privacy")
        para("What you log goes to OpenAI under its API terms, which say it doesn't train its models on API data by default. Your key stays in this iPhone's Keychain.")
    }

    // MARK: - OpenRouter

    @ViewBuilder private var openRouter: some View {
        para("OpenRouter gives access to many models with one key, and some cost nothing. Bite Log's OpenRouter preset uses Google's free Gemma 4 31B.")
        step(1, "Sign in at **openrouter.ai**.")
        step(2, "Open **Keys**, choose **Create Key**, and copy it.")
        step(3, "In Bite Log, choose **OpenRouter (free Gemma)**, paste the key, and tap **Connect**.")
        step(4, "If the model refuses with a data-policy error, OpenRouter's **privacy settings** must allow free models. Read the next section first.")
        heading("Limits")
        para("Free models allow 20 requests a minute and 50 a day; an entry takes about 3 to 6, so about 10 entries a day. Buying $10 of credit once raises the daily limit to 1,000. A free model can be busy at times: add a second model in Settings as a backup.")
        heading("Privacy")
        para("Free models run on hosts whose terms may let them keep or train on what you send. If that matters to you, use Claude or your own computer instead.")
    }

    // MARK: - your own computer

    @ViewBuilder private var ownComputer: some View {
        pitch
        warning("Check this first", [
            "**Memory: 16 GB at the very least, 32 GB to run it well.** With less, the models that fit get entries wrong. Most 8 GB laptops can't do it.",
            "**A Mac with Apple silicon (M1 or later), or a PC with a graphics card that has 12 GB or more of its own memory.** Intel Macs and PCs without such a card run it far too slowly.",
            "**It must stay on and awake.** Away from home, entries wait in the app until you're back, unless you add Tailscale (at the end of this guide).",
            "**About 20 GB of free disk space** for the download.",
            "A phone, tablet, Chromebook or Raspberry Pi can't run it.",
        ], footer: "If any of these rule you out, use Claude, OpenAI or OpenRouter instead: they take a few minutes to set up.")
        heading("What you need")
        para("A Mac with Apple silicon is easiest: the model uses its memory directly. A PC works with a graphics card (NVIDIA) holding the model in its own memory.")
        modelRow("Gemma 4 26B-A4B (recommended)", "Uses about 18 GB. A Mac with 32 GB or more, or a graphics card with 24 GB. Fast: about 2 seconds an entry on a recent Mac.")
        modelRow("Gemma 4 12B (smallest that works well)", "Uses about 10 GB. A Mac with 24 GB, or 16 GB with the shorter setting below, or a graphics card with 12 GB. Slower, but gets entries right.")
        modelRow("Smaller models", "Gemma 4 E4B and others fit in 8 GB, but in our tests they missed misheard food names and got totals wrong. Not recommended.")
        heading("Easiest: have a coding agent set it up")
        para("Running a model server is technical work. Unless you've done it before, let an AI coding agent do it for you: it reads your computer's hardware, installs what's needed, starts the server and tests it.")
        step(1, "Install a coding agent on the computer, like **Claude Code** (claude.com/claude-code). It works in the Terminal and needs a Claude subscription or API key.")
        step(2, "Start it and paste this request:")
        code(Self.agentPrompt)
        step(3, "When it's done, it tells you the address and model name. In Bite Log, choose **Your own computer**, enter the address, tap **Choose from the server's list**, turn on **Reads photos**, and tap **Connect**. Allow Local Network access when the iPhone asks.")
        heading("Or do it by hand, with llama.cpp")
        step(1, "On a Mac, install Homebrew from **brew.sh**, then in Terminal:")
        code("brew install llama.cpp")
        step(2, "Start the model. The first run downloads it (about 17 GB for 26B-A4B, 7 GB for 12B) with its photo reader:")
        code("llama-server -hf unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL -c 32768 --jinja --host 0.0.0.0 --port 8080")
        para("For Gemma 4 12B:")
        code("llama-server -hf google/gemma-4-12B-it-qat-q4_0-gguf:Q4_0 -c 32768 --jinja --host 0.0.0.0 --port 8080")
        para("On a 16 GB Mac, use -c 16384 instead of -c 32768: it halves the memory for the conversation, which is still enough for an entry.")
        step(3, "Find the computer's name: on a Mac, **System Settings → General → Sharing**, under Local hostname, like my-mac.local.")
        step(4, "In Bite Log, choose **Your own computer** and enter the address with the name and port:")
        code("http://my-mac.local:8080/v1")
        step(5, "Tap **Choose from the server's list**, turn on **Reads photos**, and tap **Connect**. Allow Local Network access when the iPhone asks.")
        heading("Or with LM Studio")
        para("LM Studio (lmstudio.ai) does the same with buttons, on a Mac or PC: download Gemma 4 26B-A4B or 12B in it, start its server with serving on the local network turned on, and use http://your-computer.local:1234/v1 as the address.")
        heading("Keep it at home")
        para("This serves the model to every device on your network, so use it only on Wi-Fi you trust. To require a key, add --api-key followed by a password of your choice to the command, and paste the same password as the key in Bite Log.")
        heading("Use it away from home, with Tailscale")
        para("Tailscale (tailscale.com, free for personal use) joins your phone and computer into a private network that works from anywhere: cellular, work, travel. Your entries still go only to your computer, encrypted, and nothing is opened to the internet.")
        step(1, "Install Tailscale on the computer and on your iPhone, and sign in to both with the same account (an email address works).")
        step(2, "On the computer, in Terminal, share the model server with your own devices:")
        code("tailscale serve --bg 8080")
        para("The first time, it prints a link to turn on Serve for your account: open it, tap Enable, and run the command again. On a Mac with Tailscale from the App Store, the command is /Applications/Tailscale.app/Contents/MacOS/Tailscale instead of tailscale.")
        step(3, "It prints the computer's Tailscale address, like https://my-mac.tail1234.ts.net. In Bite Log, use it with /v1 on the end:")
        code("https://my-mac.tail1234.ts.net/v1")
        para("Keep Tailscale connected on the iPhone (its VPN switch, or turn on VPN On Demand in its settings). Only your own signed-in devices can reach this address. If you only use Tailscale, you can start the server with --host 127.0.0.1 instead of 0.0.0.0, so it isn't on your home Wi-Fi at all.")
    }

    /// Why run it at home: the reason Bite Log exists.
    private var pitch: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The most private way to use Bite Log", systemImage: "house.fill")
                .font(.headline).foregroundStyle(.tint)
            para("Bite Log was made so your health data stays yours. With Claude, OpenAI or OpenRouter, what you log still passes through a company's servers, under that company's terms.")
            para("Run the model on your own computer and it doesn't. Your meals, photos and voice never leave your home. No company sees them, so nothing can be kept, sold, or trained on, and every entry is free.")
            para("It's how Bite Log was meant to run: the app grew out of the local AI movement, where your data stays on hardware you own, and it's how its author uses it every day.")
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    /// What to ask a coding agent: everything we learned picking and serving
    /// the model, so it doesn't have to guess.
    static let agentPrompt = """
        Set up a local AI model server on this computer for the Bite Log iPhone app, which connects to an OpenAI-compatible chat API on my home network and needs tool calling and image input.

        1. Check this computer first, and if it can't run this well, stop and tell me before installing anything: it needs an Apple silicon Mac with at least 16 GB of memory, or a PC with an NVIDIA graphics card with at least 12 GB of its own memory, and about 20 GB of free disk space. Intel Macs and computers without such a graphics card are too slow.
        2. Install llama.cpp (on a Mac: brew install llama.cpp).
        3. Pick the model by memory:
           - 32 GB or more (or a 24 GB GPU): Gemma 4 26B-A4B, llama-server -hf unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL (uses about 18 GB)
           - 16 to 24 GB (or a 12 GB GPU): Gemma 4 12B, llama-server -hf google/gemma-4-12B-it-qat-q4_0-gguf:Q4_0 (about 10 GB)
           - less: stop and tell me; smaller models aren't accurate enough.
        4. Serve it with --jinja, -c 32768 (-c 16384 on a 16 GB computer), --host 0.0.0.0 --port 8080, keeping the vision projector that -hf downloads.
        5. Make it start automatically when I log in, and keep the computer from sleeping while it serves.
        6. Test it: send a chat request with a tool definition and one with an image to http://localhost:8080/v1/chat/completions.
        7. Tell me the address to enter in the app (http://<this computer's local hostname>.local:8080/v1) and the model name the server lists at /v1/models.
        8. Ask me whether I want to use it away from home too. If so, set up Tailscale: install it, have me sign in, run tailscale serve --bg 8080 (on a Mac with the App Store version, /Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 8080; the first run prints a link for me to enable Serve, then run it again), test https://<this computer's Tailscale name>.ts.net/v1/models, and give me that address with /v1 for the app. Tell me to install Tailscale on my iPhone and sign in with the same account.
        """

    // MARK: - pieces

    /// A boxed list of things that rule this out, read before starting.
    private func warning(_ title: String, _ points: [String], footer: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            ForEach(points, id: \.self) { p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    // Markdown from a String needs LocalizedStringKey to render **bold**
                    Text(LocalizedStringKey(p)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(footer).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.4)))
    }

    /// Text from a literal, so its **bold** renders.
    private func para(_ s: LocalizedStringKey) -> some View {
        Text(s).fixedSize(horizontal: false, vertical: true)
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.headline).padding(.top, 6)
    }

    private func step(_ n: Int, _ s: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.bold().monospacedDigit()).foregroundStyle(.tint).frame(width: 18, alignment: .trailing)
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelRow(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.subheadline.bold())
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A command or request to copy.
    private func code(_ s: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(verbatim: s)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = s
                copied = s
            } label: {
                Label(copied == s ? "Copied" : "Copy", systemImage: copied == s ? "checkmark" : "doc.on.doc")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
