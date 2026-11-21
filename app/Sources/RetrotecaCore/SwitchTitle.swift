import Foundation

/// Switch and Switch 2 title IDs: which game a file belongs to, and whether it is the base game, an update or a DLC.
/// Read from the file name ("Game [010015100B514000][v0].xci") or matched by name: reading the package itself needs the user's keys.
public enum SwitchTitle {
    public enum Role: String, Codable, Sendable {
        case base, update, dlc
    }

    public static let extensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]

    /// "[010015100B514800]" → "010015100B514800".
    /// Also a bare ID ("0400A3A01EE4C000.nup", as dump tools name NUP files): 16 hex digits on their own, starting
    /// 01 (Switch) or 04 (Switch 2), so a hash or a longer hex run is not taken for one.
    public static func titleID(inFileName name: String) -> String? {
        (firstMatch(#"\[([0-9A-Fa-f]{16})\]"#, in: name)
            ?? firstMatch(#"(?<![0-9A-Fa-f])(0[14][0-9A-Fa-f]{14})(?![0-9A-Fa-f])"#, in: name)).map { $0.uppercased() }
    }

    /// "[v65536]" → 65536.
    public static func version(inFileName name: String) -> Int? {
        firstMatch(#"\[v(\d+)\]"#, in: name).flatMap { Int($0) }
    }

    /// The low 12 bits: 0x000 = the game, 0x800 = its update; a DLC has its own block (+0x1000) with its index there.
    public static func role(of titleID: String) -> Role? {
        guard let value = UInt64(titleID, radix: 16) else { return nil }
        let low = value & 0xFFF
        if low == 0 && (value >> 12) & 1 == 0 { return .base }
        if low == 0x800 { return .update }
        return .dlc
    }

    /// The base game's title ID for any of its files.
    public static func baseID(of titleID: String) -> String? {
        guard let value = UInt64(titleID, radix: 16), let role = role(of: titleID) else { return nil }
        let base: UInt64
        switch role {
        case .base: base = value
        case .update: base = value & ~0xFFF
        case .dlc: base = (value & ~0xFFF) - 0x1000
        }
        return String(format: "%016llX", base)
    }

    /// Titles compared without punctuation, case or "The": "Legend of Zelda, The - Tears of the Kingdom" = "The Legend of Zelda: Tears of the Kingdom".
    public static func normalized(_ title: String) -> String {
        let moved = movingArticleToFront(title)
        let folded = moved.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0 != "the" }
        return words.joined(separator: " ")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// A game profile of a native engine: the games it knows how to build.
public struct NXProfile: Hashable, Sendable {
    public let titleID: String
    public let name: String
    /// Builds the profile was brought up on, as the engine's game list says ("1.2.1 (and 1.0.0)").
    public var builds: String?

    public init(titleID: String, name: String, builds: String? = nil) {
        self.titleID = titleID
        self.name = name
        self.builds = builds
    }

    /// `game.py list`: "<id>\t<base id>\t<name>" per line.
    public static func parseList(_ text: String) -> [NXProfile] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, parts[0].count == 16, UInt64(parts[0], radix: 16) != nil else { return nil }
            return NXProfile(titleID: parts[0].uppercased(), name: parts[2])
        }
    }

    /// The "Build" column of the table in `dm/games/README.md`, by title ID.
    public static func parseBuilds(readme: String) -> [String: String] {
        var builds: [String: String] = [:]
        for line in readme.split(separator: "\n") where line.hasPrefix("| [") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3 else { continue }
            let id = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`")).uppercased()
            if id.count == 16 { builds[id] = cells[2] }
        }
        return builds
    }

    /// The profile for a file: by title ID when the name carries one, else by title.
    public static func match(titleID: String?, title: String, in profiles: [NXProfile]) -> NXProfile? {
        if let id = titleID.flatMap(SwitchTitle.baseID(of:)), let profile = profiles.first(where: { $0.titleID == id }) { return profile }
        let wanted = SwitchTitle.normalized(title)
        guard !wanted.isEmpty else { return nil }
        return profiles.first { SwitchTitle.normalized($0.name) == wanted }
    }
}

/// What a Switch package says about itself without keys: NSP and NSZ are PFS0 containers whose file names are plain,
/// and a ticket is named after its rights ID, which starts with the content's title ID ("0100c1f0051b6800….tik").
/// Some dumps also carry the content metadata as plain XML (".cnmt.xml"), with the version.
public struct SwitchPackage: Equatable, Sendable {
    public var titleIDs: [String] = []
    public var version: Int?

    public init(titleIDs: [String] = [], version: Int? = nil) {
        self.titleIDs = titleIDs
        self.version = version
    }

    /// Reads the container's header only (a few KB), so it is quick even on a network drive.
    public static func read(_ url: URL) -> SwitchPackage? {
        guard ["nsp", "nsz"].contains(url.pathExtension.lowercased()), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count == 16, head.prefix(4) == Data("PFS0".utf8) else { return nil }
        let count = Int(head.uint32(at: 4)), stringsSize = Int(head.uint32(at: 8))
        guard count > 0, count < 4096, stringsSize < 1 << 20,
              let table = try? handle.read(upToCount: count * 0x18 + stringsSize), table.count == count * 0x18 + stringsSize else { return nil }
        let strings = table.subdata(in: count * 0x18 ..< table.count)
        let dataStart = UInt64(16 + count * 0x18 + stringsSize)
        var package = SwitchPackage()
        for i in 0..<count {
            let entry = table.subdata(in: i * 0x18 ..< (i + 1) * 0x18)
            let nameOffset = Int(entry.uint32(at: 16))
            guard nameOffset < strings.count else { continue }
            let name = String(decoding: strings[nameOffset...].prefix { $0 != 0 }, as: UTF8.self)
            if name.lowercased().hasSuffix(".tik"), name.count >= 20 {
                let id = String(name.prefix(16)).uppercased()
                if UInt64(id, radix: 16) != nil, !package.titleIDs.contains(id) { package.titleIDs.append(id) }
            } else if name.lowercased().hasSuffix(".cnmt.xml") {
                let offset = entry.uint64(at: 0), size = entry.uint64(at: 8)
                if size < 64 << 10, (try? handle.seek(toOffset: dataStart + offset)) != nil, let xml = try? handle.read(upToCount: Int(size)) {
                    package.version = parseVersion(String(decoding: xml, as: UTF8.self))
                    if let id = parseTitleID(String(decoding: xml, as: UTF8.self)), !package.titleIDs.contains(id) { package.titleIDs.insert(id, at: 0) }
                }
            }
        }
        return package.titleIDs.isEmpty && package.version == nil ? nil : package
    }

    static func parseVersion(_ xml: String) -> Int? {
        guard let start = xml.range(of: "<Version>"), let end = xml.range(of: "</Version>", range: start.upperBound..<xml.endIndex) else { return nil }
        return Int(xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    static func parseTitleID(_ xml: String) -> String? {
        guard let start = xml.range(of: "<Id>"), let end = xml.range(of: "</Id>", range: start.upperBound..<xml.endIndex) else { return nil }
        let id = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "").uppercased()
        return id.count == 16 && UInt64(id, radix: 16) != nil ? id : nil
    }
}

/// One file of a Switch game: whose it is and what it is, from its name or, failing that, its container.
public struct SwitchFileInfo: Equatable, Sendable {
    public var titleID: String?
    public var version: Int?
    public var role: SwitchTitle.Role?

    public var baseID: String? { titleID.flatMap(SwitchTitle.baseID(of:)) }

    public init(titleID: String? = nil, version: Int? = nil, role: SwitchTitle.Role? = nil) {
        self.titleID = titleID
        self.version = version
        self.role = role
    }

    /// Words in a file name that mark an update or a DLC when the name carries no title ID.
    static let updateWords = ["update", "aggiornamento", "upd", "patch"]
    static let dlcWords = ["dlc", "add-on", "addon", "expansion pass", "season pass"]

    public static func identify(_ url: URL, readPackage: Bool = true) -> SwitchFileInfo {
        let name = url.lastPathComponent
        var info = SwitchFileInfo(titleID: SwitchTitle.titleID(inFileName: name), version: SwitchTitle.version(inFileName: name))
        if info.titleID == nil || info.version == nil, readPackage, let package = SwitchPackage.read(url) {
            info.titleID = info.titleID ?? package.titleIDs.first
            info.version = info.version ?? package.version
        }
        info.role = info.titleID.flatMap(SwitchTitle.role(of:)) ?? roleFromName(name)
        if info.role == .base && info.version == nil { info.version = 0 }
        return info
    }

    static func roleFromName(_ name: String) -> SwitchTitle.Role? {
        let words = SwitchTitle.normalized((name as NSString).deletingPathExtension).split(separator: " ").map(String.init)
        if words.contains(where: { updateWords.contains($0) }) { return .update }
        if words.contains(where: { dlcWords.contains($0) }) { return .dlc }
        return nil
    }

    /// The game's name without "Update", "DLC" or version words, to find its base game by title.
    public static func baseTitle(_ name: String) -> String {
        let words = SwitchTitle.normalized(cleanTitle(fromFileName: name)).split(separator: " ").map(String.init)
        return words.filter { word in
            !(updateWords + dlcWords).contains(word) && !(word.first == "v" && Int(word.dropFirst()) != nil) && Int(word.replacingOccurrences(of: ".", with: "")) == nil
        }.joined(separator: " ")
    }
}

/// The versions a game's engine profile was brought up on, from its game.tsv: "build<TAB>v327680<TAB>1.2.1<TAB>…".
public struct NXProfileVersions: Equatable, Sendable {
    /// Version number → the version players know ("1.2.1").
    public var tested: [Int: String] = [:]
    /// The version the profile packs by default ("package v327680").
    public var recommended: Int?

    public init(tested: [Int: String] = [:], recommended: Int? = nil) {
        self.tested = tested
        self.recommended = recommended
    }

    public static func parse(_ tsv: String) -> NXProfileVersions {
        var result = NXProfileVersions()
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t").map(String.init)
            guard cells.count >= 2 else { continue }
            let number = cells[1].hasPrefix("v") ? Int(cells[1].dropFirst()) : nil
            if cells[0] == "build", let number, cells.count >= 3 { result.tested[number] = cells[2] }
            if cells[0] == "package", let number { result.recommended = number }
        }
        return result
    }

    public static func load(engineRoot: URL, profiles: String, titleID: String) -> NXProfileVersions {
        let url = engineRoot.appendingPathComponent("\(profiles)/\(titleID)/game.tsv")
        return (try? String(contentsOf: url, encoding: .utf8)).map(parse) ?? NXProfileVersions()
    }

    /// The version to build among those the user has: the profile's own, else the newest it was tested on, else the newest.
    public func choose(from available: [Int]) -> Int? {
        if let recommended, available.contains(recommended) { return recommended }
        return available.filter { tested[$0] != nil }.max() ?? available.max()
    }
}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    func uint64(at offset: Int) -> UInt64 {
        subdata(in: offset..<offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
}
