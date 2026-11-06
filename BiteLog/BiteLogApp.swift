import SwiftUI

@main
struct BiteLogApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// File names in Application Support. UI tests (launched with -uitest) get
/// their own files, emptied at launch, so they never touch the user's log or
/// model list.
enum AppFiles {
    static let uiTest = CommandLine.arguments.contains("-uitest")

    static func name(_ base: String, _ ext: String) -> String {
        uiTest ? "\(base)-uitest.\(ext)" : "\(base).\(ext)"
    }

    static func resetUITestFiles() throws {
        guard uiTest else { return }
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.contains("-uitest") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}

/// Everything the screens share, opened once at launch.
struct AppModel {
    let foods: FoodDB
    let log: LogDB
    let profiles: ProfileStore
    let client: LLMClient
    let logger: Logger

    static func open() throws -> AppModel {
        try AppFiles.resetUITestFiles()
        let foods = try FoodDB.app()
        let log = try LogDB.app()
        let profiles = try ProfileStore.app()
        let client = LLMClient()
        return AppModel(foods: foods, log: log, profiles: profiles, client: client,
                        logger: Logger(foods: foods, log: log, brain: try Brain.bundled(), client: client,
                                       profiles: profiles))
    }
}

struct ContentView: View {
    @State private var model: Result<AppModel, Error>?

    var body: some View {
        switch model {
        case nil:
            ProgressView().task { model = Result { try AppModel.open() } }
        case .failure(let e):
            ContentUnavailableView("Bite Log didn't start", systemImage: "exclamationmark.triangle",
                                   description: Text(String(describing: e)))
        case .success(let m) where m.profiles.profiles.isEmpty:
            SetupView(store: m.profiles, client: m.client)
        case .success(let m):
            TabView {
                Tab("Today", systemImage: "fork.knife") {
                    NavigationStack { TodayView(model: m) }
                }
                Tab("Settings", systemImage: "gearshape") {
                    NavigationStack { SettingsView(model: m, store: m.profiles, client: m.client) }
                }
            }
        }
    }
}
