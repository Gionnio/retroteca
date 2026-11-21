import Foundation

/// Copies imported games into Retroteca's own folder, only when the user turned it on in Settings.
/// By default Retroteca never duplicates games: it remembers where they are.
public struct GameCopier {
    /// `<Application Support>/Retroteca/Games`
    public let destination: URL

    public init(destination: URL) {
        self.destination = destination
    }

    /// Copies each game's files into `Games/<platform>/` and returns the games pointing at the copies.
    /// Files already there with the same size are not copied again; a game whose copy fails keeps its original files.
    public func copy(_ games: [Game], fileManager: FileManager = .default) -> (games: [Game], failures: [String]) {
        var result: [Game] = []
        var failures: [String] = []
        for var game in games {
            let folder = destination.appendingPathComponent(game.platformID ?? "unknown", isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                var copied: [URL] = []
                for file in game.files {
                    let target = folder.appendingPathComponent(file.lastPathComponent)
                    if file.standardizedFileURL == target.standardizedFileURL || Self.sameSize(file, target, fileManager) {
                        copied.append(target)
                        continue
                    }
                    if fileManager.fileExists(atPath: target.path) {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
                    }
                    try fileManager.copyItem(at: file, to: target)
                    copied.append(target)
                }
                game.files = copied
            } catch {
                failures.append("\(game.title): \(error.localizedDescription)")
            }
            result.append(game)
        }
        return (result, failures)
    }

    private static func sameSize(_ a: URL, _ b: URL, _ fileManager: FileManager) -> Bool {
        guard let sa = (try? fileManager.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sb = (try? fileManager.attributesOfItem(atPath: b.path))?[.size] as? NSNumber else { return false }
        return sa == sb
    }
}
