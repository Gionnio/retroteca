import Foundation

/// The user's library, saved as JSON in Application Support.
public final class LibraryStore {
    public private(set) var games: [Game] = []
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Retroteca`
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Retroteca", isDirectory: true)
    }

    private struct File: Codable {
        var version: Int
        var games: [Game]
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { games = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        games = try decoder.decode(File.self, from: Data(contentsOf: fileURL)).games
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: 1, games: games)).write(to: fileURL, options: .atomic)
    }

    /// Adds games whose files are not in the library yet. Returns the ones added.
    @discardableResult
    public func add(_ newGames: [Game]) -> [Game] {
        let known = Set(games.flatMap { $0.files.map(\.standardizedFileURL) })
        let added = newGames.filter { game in !game.files.contains { known.contains($0.standardizedFileURL) } }
        games.append(contentsOf: added)
        return added
    }

    public func update(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i] = game
    }

    public func remove(ids: Set<UUID>) {
        games.removeAll { ids.contains($0.id) }
    }

    /// Replaces games by id (after identification or artwork download), keeping everything else.
    public func update(_ changed: [Game]) {
        for game in changed { update(game) }
    }

    /// Adds play time and the last start date.
    public func recordPlay(id: UUID, started: Date, ended: Date) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].lastPlayedAt = started
        games[i].playTime += max(0, ended.timeIntervalSince(started))
    }

    /// Marks games whose files disappeared, and restores the ones that came back.
    public func refreshFileStatus(fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        for i in games.indices {
            let present = games[i].files.allSatisfy(fileExists)
            if !present {
                games[i].status = .missingFiles
            } else if games[i].status == .missingFiles {
                // The build check runs afterwards and turns it ready when its app is there.
                games[i].status = games[i].platformID == nil ? .unrecognized : .needsEngine
            }
        }
    }
}
