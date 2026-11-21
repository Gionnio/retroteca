import Foundation

/// A game system (console, handheld, computer) as described in `catalog/platforms.json`.
public struct Platform: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let maker: String
    public let year: Int
    /// Extensions that belong to this platform only.
    public let extensions: [String]
    /// Extensions shared with other platforms (iso, chd, cue…): they need a closer look at the file.
    public let shared: [String]
    /// System name in libretro-thumbnails ("Nintendo - GameCube"), for artwork.
    public let thumbnails: String?

    public init(id: String, name: String, maker: String = "", year: Int = 0, extensions: [String] = [], shared: [String] = [], thumbnails: String? = nil) {
        self.id = id
        self.name = name
        self.maker = maker
        self.year = year
        self.extensions = extensions
        self.shared = shared
        self.thumbnails = thumbnails
    }

    enum CodingKeys: String, CodingKey { case id, name, maker, year, extensions, shared, thumbnails }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        maker = try c.decodeIfPresent(String.self, forKey: .maker) ?? ""
        year = try c.decodeIfPresent(Int.self, forKey: .year) ?? 0
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
        shared = try c.decodeIfPresent([String].self, forKey: .shared) ?? []
        thumbnails = try c.decodeIfPresent(String.self, forKey: .thumbnails)
    }
}

/// The list of known platforms, with lookup by extension.
public struct PlatformCatalog: Sendable {
    public let version: String
    public let platforms: [Platform]
    private let byID: [String: Platform]
    private let byExtension: [String: String]

    public init(version: String = "", platforms: [Platform]) {
        self.version = version
        self.platforms = platforms
        byID = Dictionary(platforms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var map: [String: String] = [:]
        for p in platforms {
            for ext in p.extensions { map[ext.lowercased()] = p.id }
        }
        byExtension = map
    }

    public static func load(from url: URL) throws -> PlatformCatalog {
        struct File: Decodable { let version: String; let platforms: [Platform] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return PlatformCatalog(version: file.version, platforms: file.platforms)
    }

    public func platform(id: String) -> Platform? { byID[id] }

    /// The platform an extension belongs to, or nil when unknown or shared by several systems.
    public func platformID(forExtension ext: String) -> String? { byExtension[ext.lowercased()] }

    /// Platforms that may own a shared extension (e.g. "iso" → GameCube, Wii, PS2…).
    public func candidates(forExtension ext: String) -> [Platform] {
        let e = ext.lowercased()
        if let id = byExtension[e], let p = byID[id] { return [p] }
        return platforms.filter { $0.shared.contains(e) }
    }

    /// Every extension Retroteca may import.
    public var allExtensions: Set<String> {
        Set(platforms.flatMap { $0.extensions + $0.shared }.map { $0.lowercased() })
    }
}
