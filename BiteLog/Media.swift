import Foundation

/// Voice recordings and photos for entries, as files in Application Support/media
/// (UI tests use media-uitest). The log stores their names.
enum Media {
    static func dir() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let d = base.appendingPathComponent(AppFiles.uiTest ? "media-uitest" : "media")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ name: String) throws -> URL { try dir().appendingPathComponent(name) }

    /// Saves the data under a new name with this extension; returns the name.
    static func save(_ data: Data, ext: String) throws -> String {
        let name = "\(UUID().uuidString.lowercased()).\(ext)"
        try data.write(to: url(name), options: .atomic)
        return name
    }

    /// Moves a file (a finished recording) in; returns its name.
    static func adopt(_ file: URL, ext: String) throws -> String {
        let name = "\(UUID().uuidString.lowercased()).\(ext)"
        try FileManager.default.moveItem(at: file, to: url(name))
        return name
    }

    static func remove(_ name: String?) {
        guard let name, let u = try? url(name) else { return }
        try? FileManager.default.removeItem(at: u)
    }
}
