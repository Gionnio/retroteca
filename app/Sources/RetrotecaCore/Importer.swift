import Foundation

/// Turns dropped files and folders into library entries: Switch and Switch 2 game files (NSP, XCI, NSZ, XCZ, NUP).
public struct Importer {
    public let catalog: PlatformCatalog
    /// Folder depth searched inside dropped folders.
    public var maxDepth = 4

    public init(catalog: PlatformCatalog) {
        self.catalog = catalog
    }

    /// The games found in the given files and folders.
    public func games(from urls: [URL]) -> [Game] {
        var files: [URL] = []
        for url in urls { collect(url, depth: 0, into: &files) }
        return games(fromFiles: files)
    }

    func games(fromFiles files: [URL]) -> [Game] {
        files.sorted { $0.path < $1.path }.compactMap { file in
            guard let platform = catalog.platformID(forExtension: file.pathExtension) else { return nil }
            var game = Game(title: cleanTitle(fromFileName: file.lastPathComponent), platformID: platform, files: [file], status: .needsEngine)
            game.kind = .switchNative
            game.sourceName = (file.lastPathComponent as NSString).deletingPathExtension
            return game
        }
    }

    private func collect(_ url: URL, depth: Int, into files: inout [URL]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue { files.append(url); return }
        guard depth < maxDepth, url.pathExtension != "app",
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for item in items { collect(item, depth: depth + 1, into: &files) }
    }
}
