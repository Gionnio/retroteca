import Foundation

/// GameBanana, the public archive of game mods: a game's mods, their files, and what each file contains, so only
/// mods that can work with a native build (game files, no code) are offered. Read-only; downloads go through `NXMods.add`.
public struct GameBanana: Sendable {
    public struct Mod: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let category: String?
        public let author: String?
        public let likes: Int
        public let image: URL?
        public var page: URL { URL(string: "https://gamebanana.com/mods/\(id)")! }
    }

    public struct File: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let size: Int64
        public let download: URL
        public let note: String?
        public let downloads: Int
        /// GameBanana's own check of the upload (virus scan and analysis).
        public let clean: Bool
    }

    /// What a file can do with a native build.
    public enum Fit: Equatable, Sendable {
        case works
        case codeMod
        case otherGame(String)
        case noRomFS
        case unknown
    }

    public init() {}

    private static let api = "https://gamebanana.com/apiv11"

    private func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Retroteca", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The game's id on GameBanana, by name (the closest title wins; nil when nothing matches).
    public func findGame(_ title: String) async throws -> (id: Int, name: String)? {
        var parts = URLComponents(string: "\(Self.api)/Util/Search/Results")!
        parts.queryItems = [.init(name: "_sModelName", value: "Game"), .init(name: "_sOrder", value: "best_match"),
                            .init(name: "_nPage", value: "1"), .init(name: "_sSearchString", value: title)]
        let records = ((try await json(parts.url!) as? [String: Any])?["_aRecords"] as? [[String: Any]]) ?? []
        let wanted = SwitchTitle.normalized(title)
        let games = records.compactMap { r -> (Int, String)? in
            guard let id = r["_idRow"] as? Int, let name = r["_sName"] as? String else { return nil }
            return (id, name)
        }
        return games.first { SwitchTitle.normalized($0.1) == wanted } ?? games.first { SwitchTitle.normalized($0.1).hasPrefix(wanted) || wanted.hasPrefix(SwitchTitle.normalized($0.1)) }
    }

    /// A page of the game's mods, most downloaded first, or matching `search`.
    public func mods(game: Int, page: Int = 1, search: String = "") async throws -> [Mod] {
        let text = search.trimmingCharacters(in: .whitespaces)
        var parts: URLComponents
        if text.isEmpty {
            parts = URLComponents(string: "\(Self.api)/Mod/Index")!
            parts.queryItems = [.init(name: "_nPage", value: String(page)), .init(name: "_nPerpage", value: "30"),
                                .init(name: "_aFilters[Generic_Game]", value: String(game)), .init(name: "_sSort", value: "Generic_MostDownloaded")]
        } else {
            // The index ignores names: a search goes through the game's feed.
            parts = URLComponents(string: "\(Self.api)/Game/\(game)/Subfeed")!
            parts.queryItems = [.init(name: "_nPage", value: String(page)), .init(name: "_sName", value: text)]
        }
        let records = ((try await json(parts.url!) as? [String: Any])?["_aRecords"] as? [[String: Any]]) ?? []
        return records.filter { ($0["_sModelName"] as? String ?? "Mod") == "Mod" }.compactMap(Self.mod)
    }

    static func mod(_ r: [String: Any]) -> Mod? {
        guard let id = r["_idRow"] as? Int, let name = r["_sName"] as? String else { return nil }
        let images = ((r["_aPreviewMedia"] as? [String: Any])?["_aImages"] as? [[String: Any]]) ?? []
        let image = images.first.flatMap { img -> URL? in
            guard let base = img["_sBaseUrl"] as? String, let file = (img["_sFile220"] as? String) ?? (img["_sFile"] as? String) else { return nil }
            return URL(string: "\(base)/\(file)")
        }
        return Mod(id: id, name: name, category: (r["_aRootCategory"] as? [String: Any])?["_sName"] as? String,
                   author: (r["_aSubmitter"] as? [String: Any])?["_sName"] as? String,
                   likes: r["_nLikeCount"] as? Int ?? 0, image: image)
    }

    /// The mod's downloadable files, newest first as GameBanana lists them.
    public func files(mod: Int) async throws -> [File] {
        let page = (try await json(URL(string: "\(Self.api)/Mod/\(mod)/ProfilePage")!) as? [String: Any]) ?? [:]
        return ((page["_aFiles"] as? [[String: Any]]) ?? []).compactMap(Self.file)
    }

    static func file(_ f: [String: Any]) -> File? {
        func int(_ key: String) -> Int? { (f[key] as? Int) ?? (f[key] as? String).flatMap { Int($0) } }
        guard let id = int("_idRow"), let name = f["_sFile"] as? String,
              let url = (f["_sDownloadUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        let clean = (f["_sAvResult"] as? String ?? "clean") == "clean" && (f["_sAnalysisResult"] as? String ?? "ok") == "ok"
        return File(id: id, name: name, size: Int64(int("_nFilesize") ?? 0), download: url,
                    note: (f["_sDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 }, downloads: int("_nDownloadCount") ?? 0, clean: clean)
    }

    /// The paths inside a file's archive, as GameBanana analysed them (no download).
    public func contents(file: Int) async throws -> [String] {
        let url = URL(string: "https://api.gamebanana.com/Core/Item/Data?itemtype=File&itemid=\(file)&fields=Metadata().aArchiveFilesList()")!
        let value = try await json(url)
        return ((value as? [Any])?.first as? [String]) ?? []
    }

    /// Whether a file whose archive holds these paths can work: game files (romfs) for this game, no code.
    public static func fit(of paths: [String], titleID: String) -> Fit {
        guard !paths.isEmpty else { return .unknown }
        let lower = paths.map { $0.lowercased() }
        let code = lower.contains { path in
            path.split(separator: "/").contains { ["exefs", "exefs_patches"].contains(String($0)) }
                || path.hasSuffix(".ips") || path.hasSuffix(".pchtxt") || path.hasSuffix("main.npdm")
        }
        if code { return .codeMod }
        guard lower.contains(where: { $0.split(separator: "/").contains("romfs") }) else { return .noRomFS }
        for path in paths {
            for part in path.split(separator: "/") where part.count == 16 && UInt64(part, radix: 16) != nil {
                if SwitchTitle.baseID(of: part.uppercased()) != titleID.uppercased() { return .otherGame(part.uppercased()) }
            }
        }
        return .works
    }

    /// Downloads a file into a temporary folder, keeping its name (the archive type comes from it).
    public func download(_ file: File) async throws -> URL {
        var request = URLRequest(url: file.download, timeoutInterval: 120)
        request.setValue("Retroteca", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("retroteca-gb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.name)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}
