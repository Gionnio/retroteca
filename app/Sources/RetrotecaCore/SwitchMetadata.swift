import Foundation

/// What Nintendo's own store says about a Switch game, found by title ID: title, short description, publisher,
/// release date, genres, a 2:1 banner, a square image (up to 1600 px) and the game's store page, which holds the
/// official screenshots. Only the title ID is sent.
public struct SwitchMetadata: Equatable, Sendable {
    public var title: String?
    public var summary: String?
    public var publisher: String?
    public var releaseDate: Date?
    public var genres: [String]
    public var banner: URL?
    public var square: URL?
    /// The game's page on Nintendo's site.
    public var page: URL?

    public var year: Int? { releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) } }

    /// The store's search, in one of the languages it is published in (Italian, English, German, French, Spanish, Dutch, Portuguese, Russian).
    public static func url(titleID: String, language: String?) -> URL {
        let supported = ["it", "en", "de", "fr", "es", "nl", "pt", "ru"]
        let lang = language.flatMap { supported.contains($0) ? $0 : nil } ?? "en"
        let fields = "title,excerpt,publisher,dates_released_dts,pretty_game_categories_txt,image_url_h2x1_s,image_url_h16x9_s,image_url_sq_s,url"
        let query = "fq=application_id_s:\(titleID.lowercased())%20AND%20type:GAME&q=*&rows=5&wt=json&fl=\(fields)"
        return URL(string: "https://searching.nintendo-europe.com/\(lang)/select?\(query)")!
    }

    /// The store lists a game and its later editions under one title ID: the original edition (earliest date) is the one.
    public static func parse(_ data: Data, switch2: Bool = false) -> SwitchMetadata? {
        struct Response: Decodable {
            struct Body: Decodable { let docs: [Doc] }
            struct Doc: Decodable {
                let title: String?
                let excerpt: String?
                let publisher: String?
                let dates_released_dts: [String]?
                let pretty_game_categories_txt: [String]?
                let image_url_h2x1_s: String?
                let image_url_h16x9_s: String?
                let image_url_sq_s: String?
                let url: String?
            }
            let response: Body
        }
        guard let docs = try? JSONDecoder().decode(Response.self, from: data).response.docs, !docs.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        func date(_ doc: Response.Doc) -> Date { doc.dates_released_dts?.first.flatMap(iso.date(from:)) ?? .distantFuture }
        let editions = docs.filter { switch2 || !($0.title ?? "").localizedCaseInsensitiveContains("Switch 2 Edition") }
        guard let doc = (editions.isEmpty ? docs : editions).min(by: { date($0) < date($1) }) else { return nil }
        return SwitchMetadata(title: doc.title, summary: doc.excerpt, publisher: doc.publisher,
                              releaseDate: doc.dates_released_dts?.first.flatMap(iso.date(from:)),
                              genres: doc.pretty_game_categories_txt ?? [],
                              banner: (doc.image_url_h2x1_s ?? doc.image_url_h16x9_s).flatMap(large),
                              square: doc.image_url_sq_s.flatMap(large),
                              page: doc.url.flatMap { $0.hasPrefix("/") ? URL(string: "https://www.nintendo.com\($0)") : nil })
    }

    /// "…_image500w.jpg" → "…_image1600w.jpg": the store serves the same picture in larger sizes.
    static func large(_ text: String) -> URL? {
        URL(string: text.replacingOccurrences(of: "_image500w.", with: "_image1600w."))
    }

    public static func fetch(titleID: String, language: String?) async throws -> SwitchMetadata? {
        var request = URLRequest(url: url(titleID: titleID, language: language), timeoutInterval: 20)
        request.setValue("Retroteca", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return parse(data, switch2: titleID.hasPrefix("04"))
    }

    /// Downloads one image into `destination` (replacing it); false when there is none. A large size the store
    /// does not have falls back to the size it listed.
    public static func download(_ url: URL, to destination: URL) async -> Bool {
        for candidate in [url, URL(string: url.absoluteString.replacingOccurrences(of: "_image1600w.", with: "_image500w."))].compactMap({ $0 }) {
            var request = URLRequest(url: candidate, timeoutInterval: 30)
            request.setValue("Retroteca", forHTTPHeaderField: "User-Agent")
            guard let (file, response) = try? await URLSession.shared.download(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.mimeType ?? "").hasPrefix("image/") else { continue }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.moveItem(at: file, to: destination)) != nil { return true }
        }
        return false
    }

    /// The official screenshots on a game's store page, full size (1920×1080), in page order, without the
    /// thumbnails and resized copies the page also lists.
    public static func screenshots(inPage html: String, limit: Int = 12) -> [URL] {
        let pattern = #"(?:https://www\.nintendo\.com)?/eu/media/images/06_screenshots/[^"'\s<>()]+?_\d{2}\.(?:jpg|png)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var found: [URL] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            var text = String(html[range])
            if text.hasPrefix("/") { text = "https://www.nintendo.com" + text }
            guard seen.insert(text).inserted, let url = URL(string: text) else { continue }
            found.append(url)
            if found.count == limit { break }
        }
        return found
    }

    /// Reads the store page and returns its screenshots (none when the page has none or does not answer).
    public static func fetchScreenshots(page: URL) async -> [URL] {
        var request = URLRequest(url: page, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (Macintosh) Retroteca", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }
        return screenshots(inPage: html)
    }
}
