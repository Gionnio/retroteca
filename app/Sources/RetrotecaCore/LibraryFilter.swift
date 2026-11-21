import Foundation

/// Ways to narrow the library.
public enum LibraryFilter: Hashable, Sendable {
    case all
    case favorites
    case recent
    case toInstall
    case kind(GameKind)
    case platform(String)
    case unrecognized

    /// Games played in the last 30 days count as recent.
    public static let recentInterval: TimeInterval = 30 * 24 * 3600

    public func matches(_ game: Game, now: Date = Date()) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return game.isFavorite
        case .recent:
            guard let last = game.lastPlayedAt else { return false }
            return now.timeIntervalSince(last) < Self.recentInterval
        case .toInstall: return game.status == .needsEngine
        case .kind(let kind): return game.kind == kind
        case .platform(let id): return game.platformID == id
        case .unrecognized: return game.platformID == nil
        }
    }
}

public extension Array where Element == Game {
    /// Games for a filter and a search text, sorted: last played first, then by title.
    func filtered(by filter: LibraryFilter, search: String = "", now: Date = Date()) -> [Game] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return self
            .filter { filter.matches($0, now: now) }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                switch (a.lastPlayedAt, b.lastPlayedAt) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
    }

    func count(_ filter: LibraryFilter, now: Date = Date()) -> Int {
        reduce(0) { $0 + (filter.matches($1, now: now) ? 1 : 0) }
    }

    func count(status: GameStatus) -> Int { reduce(0) { $0 + ($1.status == status ? 1 : 0) } }

    /// Platforms that have at least one game, in catalog order.
    func platformIDs(in catalog: PlatformCatalog) -> [String] {
        let used = Set(compactMap(\.platformID))
        return catalog.platforms.map(\.id).filter(used.contains)
    }
}
