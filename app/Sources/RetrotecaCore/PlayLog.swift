import Foundation

/// One time a game was played: when it started and how long it lasted.
public struct PlaySession: Codable, Equatable {
    public var gameID: UUID
    public var started: Date
    public var duration: TimeInterval

    public init(gameID: UUID, started: Date, duration: TimeInterval) {
        self.gameID = gameID
        self.started = started
        self.duration = duration
    }
}

/// Every game session, kept on this Mac only (`play-log.json`), for the profile's week.
/// Older libraries only have each game's total: the log starts with the first game played after it exists.
public final class PlayLog {
    public private(set) var sessions: [PlaySession] = []
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([PlaySession].self, from: $0) } ?? []
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sessions).write(to: fileURL, options: .atomic)
    }

    /// Records a session; under a minute does not count (a game opened and closed by mistake).
    public func record(gameID: UUID, started: Date, ended: Date) {
        let duration = ended.timeIntervalSince(started)
        guard duration >= 60 else { return }
        sessions.append(PlaySession(gameID: gameID, started: started, duration: duration))
    }

    /// Forgets the sessions of games that left the library.
    public func remove(gameIDs: Set<UUID>) {
        sessions.removeAll { gameIDs.contains($0.gameID) }
    }

    /// Time played on each of the 7 days ending today (oldest first), by the day each session started.
    public func week(endingOn today: Date = Date(), calendar: Calendar = .current) -> [(day: Date, time: TimeInterval)] {
        let last = calendar.startOfDay(for: today)
        return (0..<7).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: last)!
            let time = sessions.filter { calendar.isDate($0.started, inSameDayAs: day) }.reduce(0) { $0 + $1.duration }
            return (day, time)
        }
    }
}
