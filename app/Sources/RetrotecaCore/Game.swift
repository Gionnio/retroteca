import Foundation

/// How a game runs on the Mac.
public enum GameKind: String, Codable, CaseIterable, Sendable {
    /// Earlier versions' kinds of entry, still read from old libraries and then left out.
    case emulated
    case nativePort
    /// A Switch or Switch 2 game built into a Mac app by a native engine (nxnative, MacNativeGames).
    case switchNative
}

/// Where a game stands: can it be played right now?
public enum GameStatus: String, Codable, CaseIterable, Sendable {
    /// Ready to play.
    case ready
    /// Its engine (emulator, port, native build) is not installed yet.
    case needsEngine
    /// The console could not be told from the file alone (shared extensions like .iso).
    case unrecognized
    /// The game's files are gone from where they were.
    case missingFiles
}

public struct Game: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// `Platform.id`, or nil while unrecognized.
    public var platformID: String?
    public var kind: GameKind
    /// The game's files: one file, or several (disc images, base + update).
    public var files: [URL]
    public var status: GameStatus
    public var isFavorite: Bool
    public var addedAt: Date
    public var lastPlayedAt: Date?
    /// Total play time in seconds.
    public var playTime: TimeInterval
    public var year: Int?
    public var coverURL: URL?
    /// Emulator chosen by the user for this game; nil = the platform's default.
    public var engineID: String?
    /// Game code read from the disc or the cartridge (e.g. "GM8E01", "SLUS-20062").
    public var serial: String?
    /// Consoles still possible for an unrecognized disc, when its headers narrowed them down.
    public var candidatePlatforms: [String]?
    /// Artwork downloaded by Retroteca: wide image for the Vetrina (screenshot or title screen).
    public var backdropURL: URL?
    /// SHA-1 of the game's ROM (Game Boy games, for their native build), read once.
    public var romSHA1: String?
    /// The game's logo (transparent PNG), shown on its page in place of the written title.
    public var logoURL: URL?
    /// Last time Retroteca looked for the logo, so a game without one is not asked again at every launch.
    public var logoCheckedAt: Date?
    /// The file name the game was imported with, used to match artwork ("Super Mario World (USA)").
    public var sourceName: String?
    /// The game file inside a .zip or .7z (the archive itself stays where it is, never extracted to disk).
    public var archiveEntry: String?
    /// Last time Retroteca looked for artwork: not found is retried after a while, not at every launch.
    public var artworkCheckedAt: Date?
    /// Switch games: the Mac app Retroteca built from the user's files.
    public var nativeApp: URL?
    /// Switch games: the base game's title ID, from the file names or the engine's profile.
    public var titleID: String?
    /// Description, publisher and genres (Title DB for Switch games), in the user's language when available.
    public var summary: String?
    public var publisher: String?
    public var genres: [String]?
    /// Screenshots downloaded into the artwork folder.
    public var screenshots: [URL]?
    /// Last time Retroteca asked Title DB about this game.
    public var metadataCheckedAt: Date?
    /// The app was found on the Mac (built by another front end), not built by Retroteca.
    public var foundOnMac: Bool?
    /// Switch games: the version to build (nil = the one the engine's profile recommends among the user's).
    public var buildVersion: Int?
    /// Switch games: what the app was last built from, to tell when an update or a newer engine asks for a rebuild.
    public var builtFiles: [String]?
    public var builtVersion: Int?
    public var builtEngine: String?

    public init(id: UUID = UUID(), title: String, platformID: String?, kind: GameKind = .emulated, files: [URL],
                status: GameStatus, isFavorite: Bool = false, addedAt: Date = Date(), lastPlayedAt: Date? = nil,
                playTime: TimeInterval = 0, year: Int? = nil, coverURL: URL? = nil, engineID: String? = nil) {
        self.id = id
        self.title = title
        self.platformID = platformID
        self.kind = kind
        self.files = files
        self.status = status
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.playTime = playTime
        self.year = year
        self.coverURL = coverURL
        self.engineID = engineID
    }

    /// Total size of the game's files on disk, in bytes.
    public var size: Int64 {
        files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }
}

/// A readable title from a file name: drops the extension, tags in brackets and underscores.
/// "Super Mario World (USA) [!].sfc" → "Super Mario World".
public func cleanTitle(fromFileName name: String) -> String {
    var base = (name as NSString).deletingPathExtension
    for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
        while let start = base.range(of: open), let end = base.range(of: close, range: start.upperBound..<base.endIndex) {
            base.removeSubrange(start.lowerBound..<end.upperBound)
        }
    }
    base = base.replacingOccurrences(of: "_", with: " ")
    let words = base.split(separator: " ", omittingEmptySubsequences: true)
    let result = movingArticleToFront(words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -.,")))
    return result.isEmpty ? (name as NSString).deletingPathExtension : result
}

/// No-Intro puts articles last: "Legend of Zelda, The - The Wind Waker" → "The Legend of Zelda - The Wind Waker".
public func movingArticleToFront(_ title: String) -> String {
    for article in ["The", "A", "An", "Les", "Le", "La", "Il", "Lo", "Die", "Der", "Das", "El", "Los"] {
        let suffix = ", \(article)"
        if title.hasSuffix(suffix) { return "\(article) " + title.dropLast(suffix.count) }
        if let range = title.range(of: suffix + " - ") {
            return "\(article) " + title[..<range.lowerBound] + " - " + title[range.upperBound...]
        }
    }
    return title
}
