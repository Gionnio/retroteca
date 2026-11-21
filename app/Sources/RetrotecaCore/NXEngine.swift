import Foundation

/// A native engine from `catalog/native-engines.json`: builds the user's Switch games into Mac apps on the user's Mac.
public struct NativeEngine: Codable, Hashable, Identifiable, Sendable {
    public struct Requirements: Codable, Hashable, Sendable {
        public let macOS: String
        public let xcode: String
        public let python: String
        public let brew: [String]
        public let casks: [String]
        public let pythonRequirements: String
    }

    /// Another branch to build with, e.g. upstream plus fixes not yet merged for older Macs.
    public struct Channel: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let repo: String
        public let branch: String
        public let note: String?
    }

    public let id: String
    public let name: String
    /// The repository the commit comes from: upstream's, or a channel's fork.
    public var repo: String
    public let license: String
    /// The commit Retroteca was tested with (the engine has no releases), or the newer one the user moved to.
    public var commit: String
    public var committedAt: String?
    public let platforms: [String]
    public let requires: Requirements
    public let script: String
    public let profiles: String
    public let credit: String?
    public let channels: [Channel]?

    public var shortCommit: String { String(commit.prefix(8)) }
    public var repoURL: URL { URL(string: "https://github.com/\(repo)")! }

    /// The same engine at another commit.
    public func at(commit: String, committedAt: String?, repo: String? = nil) -> NativeEngine {
        var copy = self
        copy.commit = commit
        copy.committedAt = committedAt
        if let repo { copy.repo = repo }
        return copy
    }
}

/// What a newer commit of an engine brings, from GitHub's comparison of the commit in use with the latest.
public struct NXEngineUpdate: Equatable, Sendable {
    public let latest: String
    public let latestDate: String?
    /// Commits after the one in use.
    public let count: Int
    /// Games the user has, with how many of the new commits name them ("Ocarina of Time" → 12).
    public let gameMentions: [String: Int]
    /// The front-end contract (docs/frontends.md) changed: Retroteca may not read everything the new build reports.
    public let contractChanged: Bool
    /// The Python requirements changed: the environment is set up again.
    public let requirementsChanged: Bool
    /// The shader chain changed (`dm/gfx/nvn/dmsh_chain.h`): every game's next build translates its shaders from scratch,
    /// which takes hours for the largest and as much room again for the new caches.
    public let shadersChanged: Bool
    public let compareURL: URL

    /// The file that names the shader chain a build uses.
    public static let chainFile = "dm/gfx/nvn/dmsh_chain.h"

    public init(latest: String, latestDate: String?, count: Int, gameMentions: [String: Int], contractChanged: Bool,
                requirementsChanged: Bool, shadersChanged: Bool = false, compareURL: URL) {
        self.latest = latest
        self.latestDate = latestDate
        self.count = count
        self.gameMentions = gameMentions
        self.contractChanged = contractChanged
        self.requirementsChanged = requirementsChanged
        self.shadersChanged = shadersChanged
        self.compareURL = compareURL
    }

    /// A game's short name for matching commit messages: "The Legend of Zelda: Ocarina of Time" → "Ocarina of Time".
    public static func shortName(_ name: String) -> String {
        guard let colon = name.range(of: ": ") else { return name }
        return String(name[colon.upperBound...])
    }

    /// GitHub's `compare/<commit>...<latest>` answer, read against the user's games.
    public static func parse(compare data: Data, engine: NativeEngine, latest: String, latestDate: String?, games: [String]) -> NXEngineUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let count = object["ahead_by"] as? Int ?? 0
        let messages = ((object["commits"] as? [[String: Any]]) ?? []).compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }
        let files = ((object["files"] as? [[String: Any]]) ?? []).compactMap { $0["filename"] as? String }
        var mentions: [String: Int] = [:]
        for game in Set(games.map(shortName)) where game.count >= 4 {
            let n = messages.filter { $0.localizedCaseInsensitiveContains(game) }.count
            if n > 0 { mentions[game] = n }
        }
        return NXEngineUpdate(latest: latest, latestDate: latestDate, count: count, gameMentions: mentions,
                              contractChanged: files.contains("docs/frontends.md"),
                              requirementsChanged: files.contains(engine.requires.pythonRequirements),
                              // GitHub lists at most 300 files: a full list may hide the chain, so it counts as changed.
                              shadersChanged: files.contains(chainFile) || files.count >= 300,
                              compareURL: URL(string: "https://github.com/\(engine.repo)/compare/\(engine.commit)...\(latest)")!)
    }
}

public struct NativeEngineCatalog: Sendable {
    public let engines: [NativeEngine]

    public init(engines: [NativeEngine]) { self.engines = engines }

    public static func load(from url: URL) throws -> NativeEngineCatalog {
        struct File: Decodable { let engines: [NativeEngine] }
        return NativeEngineCatalog(engines: try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).engines)
    }

    public func engine(id: String) -> NativeEngine? { engines.first { $0.id == id } }
    public func engine(for platformID: String) -> NativeEngine? { engines.first { $0.platforms.contains(platformID) } }
}

/// Where Retroteca keeps an engine and what it builds: `~/Library/Application Support/Retroteca/NX`.
public struct NXPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: NXPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NXPaths(root: support.appendingPathComponent("Retroteca/NX", isDirectory: true))
    }

    public var engine: URL { root.appendingPathComponent("nxnative", isDirectory: true) }
    public var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    public var python: URL { venv.appendingPathComponent("bin/python3") }
    /// The user's console keys: a private copy (0600), never shown or logged.
    public var keys: URL { root.appendingPathComponent("keys/prod.keys") }
    /// Per game: links to the user's files (never copies), the folder the engine reads.
    public func input(_ titleID: String) -> URL { root.appendingPathComponent("games/\(titleID)", isDirectory: true) }
    /// Per game: extraction, shader caches and logs, on the disk the games are built on.
    public func work(_ titleID: String) -> URL { workRoot.appendingPathComponent(titleID, isDirectory: true) }
    /// The build folders' parent: on the chosen disk, or on the Mac.
    public var workRoot: URL { GamesLocation.buildRoot(on: GamesLocation.volume) ?? root.appendingPathComponent("work", isDirectory: true) }
    /// Every place build folders may be: the Mac's, and the chosen disk's while it is connected.
    public var workRoots: [URL] {
        var roots = [root.appendingPathComponent("work", isDirectory: true)]
        if let disk = GamesLocation.buildRoot(on: GamesLocation.volume), GamesLocation.isAvailable { roots.append(disk) }
        return roots
    }
    /// What the engine's builds no longer use (other chains' libraries and compile caches), moved there instead of deleted.
    public func obsolete(_ titleID: String) -> URL { work(titleID).appendingPathComponent("obsolete", isDirectory: true) }
    /// Every game's obsolete folder.
    public func allObsolete() -> [URL] {
        let games = workRoots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        return games.map { $0.appendingPathComponent("obsolete", isDirectory: true) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where new apps go: `~/Applications/Retroteca`, or the Retroteca folder of the chosen disk.
    public static var appsFolder: URL { GamesLocation.appsFolder(on: GamesLocation.volume) }
}

/// What the engine needs on this Mac, and what is missing.
public struct NXToolchain: Sendable, Equatable {
    public enum Item: String, CaseIterable, Sendable {
        case macOS, xcode, metal, homebrew, brewPackages, dotnet, python, engine, venv, keys
    }

    public var missing: [Item: String] = [:]
    public var xcodeVersion: String?
    public var missingFormulas: [String] = []
    public var missingCasks: [String] = []

    public var isReady: Bool { missing.isEmpty }
    /// What Retroteca can install by itself (the rest needs the user: Xcode, keys).
    public var installable: Set<Item> { Set(missing.keys).intersection([.brewPackages, .dotnet, .python, .engine, .venv]) }

    public init() {}

    /// Checks everything without changing anything.
    public static func check(_ engine: NativeEngine, paths: NXPaths, brew: URL?) -> NXToolchain {
        var result = NXToolchain()
        let wanted = engine.requires.macOS.split(separator: ".").compactMap { Int($0) }
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: wanted.first ?? 0, minorVersion: wanted.dropFirst().first ?? 0, patchVersion: 0)) {
            result.missing[.macOS] = "macOS \(engine.requires.macOS)"
        }
        let xcode = run("/usr/bin/xcodebuild", ["-version"])?.split(separator: "\n").first.map(String.init)
        result.xcodeVersion = xcode
        if xcode?.hasPrefix("Xcode \(engine.requires.xcode)") != true {
            result.missing[.xcode] = "Xcode \(engine.requires.xcode)"
        } else if run("/usr/bin/xcrun", ["-f", "metal"]) == nil {
            result.missing[.metal] = "Metal Toolchain"
        }
        if let brew {
            let formulas = Set((run(brew.path, ["list", "--formula", "-1"]) ?? "").split(separator: "\n").map(String.init))
            result.missingFormulas = engine.requires.brew.filter { !formulas.contains($0) }
            if !result.missingFormulas.isEmpty { result.missing[.brewPackages] = result.missingFormulas.joined(separator: ", ") }
            let casks = Set((run(brew.path, ["list", "--cask", "-1"]) ?? "").split(separator: "\n").map(String.init))
            result.missingCasks = engine.requires.casks.filter { !casks.contains($0) }
            let hasDotnet = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/dotnet") || FileManager.default.isExecutableFile(atPath: "/usr/local/share/dotnet/dotnet")
            if !result.missingCasks.isEmpty && !hasDotnet { result.missing[.dotnet] = ".NET SDK" } else { result.missingCasks = [] }
            if pythonExecutable(engine) == nil { result.missing[.python] = "Python \(engine.requires.python)" }
        } else {
            result.missing[.homebrew] = "Homebrew"
        }
        if !FileManager.default.fileExists(atPath: paths.engine.appendingPathComponent(engine.script).path) || currentCommit(paths) != engine.commit {
            result.missing[.engine] = "\(engine.name) \(engine.shortCommit)"
        }
        if !FileManager.default.isExecutableFile(atPath: paths.python.path) || !FileManager.default.fileExists(atPath: paths.venv.appendingPathComponent(".retroteca-ready").path) {
            result.missing[.venv] = "Python environment"
        }
        if !FileManager.default.fileExists(atPath: paths.keys.path) { result.missing[.keys] = "prod.keys" }
        return result
    }

    /// An arm64 Python of the version the engine wants, from Homebrew.
    public static func pythonExecutable(_ engine: NativeEngine) -> URL? {
        ["/opt/homebrew/bin/python\(engine.requires.python)", "/opt/homebrew/opt/python@\(engine.requires.python)/bin/python\(engine.requires.python)"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func currentCommit(_ paths: NXPaths) -> String? {
        run("/usr/bin/git", ["-C", paths.engine.path, "rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// The user's console keys. Checked for shape only; the content is never shown, logged or sent anywhere.
public enum NXKeys {
    public enum Failure: LocalizedError {
        case notKeys
        public var errorDescription: String? { "This file does not look like prod.keys: the keys exported from your console are needed." }
    }

    /// Copies the file into Retroteca's private folder with permissions 0600.
    public static func importKeys(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        guard data.count < 256 << 10, let text = String(data: data, encoding: .utf8),
              text.contains("header_key"), text.split(separator: "\n").filter({ $0.contains("=") }).count >= 5 else { throw Failure.notKeys }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Keys another Switch app on this Mac already uses, to offer instead of a file picker.
    public static func existingCandidates() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["NXLibrary/keys/prod.keys", "Ryujinx/system/prod.keys", "eden/keys/prod.keys", "citron/keys/prod.keys"]
            .map { support.appendingPathComponent($0) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }
}

/// One line of the engine's `--progress json` stream (docs/frontends.md).
public enum NXEvent: Equatable, Sendable {
    case stage(k: Int, n: Int, name: String, step: String)
    case step(k: Int, name: String, step: String)
    case progress(k: Int, done: Double?, total: Double?, unit: String, note: String, fraction: Double?, eta: Double?)
    case stageEnd(k: Int, name: String, ok: Bool, summary: String, elapsed: Double, warn: Bool)
    case game(titleID: String, name: String, version: String, bundleID: String, out: String?, icon: String?)
    case say(String)

    public static func parse(_ line: String) -> NXEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = object["ev"] as? String else { return nil }
        func s(_ key: String) -> String { object[key] as? String ?? "" }
        func i(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        func d(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        switch ev {
        case "stage": return .stage(k: i("k"), n: i("n"), name: s("name"), step: s("step"))
        case "step": return .step(k: i("k"), name: s("name"), step: s("step"))
        case "progress": return .progress(k: i("k"), done: d("done"), total: d("total"), unit: s("unit"), note: s("note"), fraction: d("frac"), eta: d("eta"))
        case "stage_end": return .stageEnd(k: i("k"), name: s("name"), ok: object["ok"] as? Bool ?? false, summary: s("summary"),
                                           elapsed: d("elapsed") ?? 0, warn: object["warn"] as? Bool ?? false)
        case "game": return .game(titleID: s("title_id"), name: s("name"), version: s("version"), bundleID: s("bundle_id"),
                                  out: object["out"] as? String, icon: object["icon"] as? String)
        case "say": return .say(s("msg"))
        default: return nil
        }
    }
}

/// A build as the build screen shows it: stages with their outcome, the current step, the log.
public struct NXBuildState: Equatable, Sendable {
    public struct Stage: Equatable, Sendable, Identifiable {
        public let k: Int
        public var name: String
        public var step: String = ""
        public var done: Double?
        public var total: Double?
        public var unit: String = ""
        public var note: String = ""
        public var fraction: Double?
        public var eta: Double?
        public var finished = false
        public var ok = true
        public var warn = false
        public var summary = ""
        public var elapsed: Double = 0
        /// When the stage started here: stages that cannot count their work (a pipeline archive) show the time spent.
        public var startedAt: Date?
        public var id: Int { k }
    }

    public var stages: [Stage] = []
    public var stageCount = 0
    public var current: Int?
    public var gameName: String?
    public var version: String?
    public var bundleID: String?
    public var output: String?
    public var icon: String?
    /// Messages for the log, newest last (the build screen shows the tail).
    public var log: [String] = []
    /// Messages starting with "[RED] ": errors, or warnings the user should read.
    public var warnings: [String] = []

    public init() {}

    public mutating func apply(_ event: NXEvent) {
        switch event {
        case let .stage(k, n, name, step):
            stageCount = max(stageCount, n)
            current = k
            if let i = stages.firstIndex(where: { $0.k == k }) { stages[i].name = name; stages[i].step = step } else { stages.append(Stage(k: k, name: name, step: step, startedAt: Date())) }
            log.append("[\(k)/\(n)] \(name)")
        case let .step(k, _, step):
            if let i = stages.firstIndex(where: { $0.k == k }) { stages[i].step = step; stages[i].done = nil; stages[i].total = nil; stages[i].fraction = nil }
        case let .progress(k, done, total, unit, note, fraction, eta):
            guard let i = stages.firstIndex(where: { $0.k == k }) else { return }
            stages[i].done = done; stages[i].total = total; stages[i].unit = unit; stages[i].note = note
            stages[i].fraction = fraction; stages[i].eta = eta
        case let .stageEnd(k, name, ok, summary, elapsed, warn):
            if let i = stages.firstIndex(where: { $0.k == k }) {
                stages[i].finished = true; stages[i].ok = ok; stages[i].warn = warn; stages[i].summary = summary; stages[i].elapsed = elapsed
                stages[i].fraction = 1
            }
            log.append((ok ? "✓ " : "✗ ") + name + (summary.isEmpty ? "" : " — \(summary)"))
        case let .game(_, name, version, bundleID, out, icon):
            gameName = name; self.version = version; self.bundleID = bundleID; output = out; self.icon = icon
        case let .say(message):
            log.append(message)
            if message.contains("[RED] ") { warnings.append(message.replacingOccurrences(of: "[RED] ", with: "")) }
        }
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// The last error the engine explained, for the message when a build stops.
    public var lastError: String? { warnings.last }

    /// The whole build's progress, from 0 to 1: finished stages plus the current one's share.
    public var overallFraction: Double {
        guard stageCount > 0 else { return 0 }
        let finished = Double(stages.filter(\.finished).count)
        let partial = stages.first { $0.k == current && !$0.finished }?.fraction ?? 0
        return min(1, (finished + partial) / Double(stageCount))
    }
}

/// The engine's command line for one game: a Mac app from the files in `input`.
public enum NXBuildCommand {
    /// - Parameter icon: an image for the app when the game's files carry none (Switch 2 NUP containers often do not).
    /// - Parameter iconIsFallback: the engine takes it as `--fallback-icon`, used only when the game has no icon of its own;
    ///   older engines know only `--icon`, which replaces the game's.
    public static func arguments(engine: NativeEngine, paths: NXPaths, titleID: String, output: URL, language: String?, needsKeys: Bool,
                                 package: Int? = nil, icon: URL? = nil, iconIsFallback: Bool = false) -> [String] {
        var arguments = [paths.engine.appendingPathComponent(engine.script).path, paths.input(titleID).path,
                         "--platform", "mac-app", "--progress", "json",
                         "--work-dir", paths.work(titleID).path, "-o", output.path]
        if needsKeys { arguments += ["-k", paths.keys.path] }
        if let language { arguments += ["-l", language] }
        if let package { arguments += ["-p", "v\(package)"] }
        if let icon { arguments += [iconIsFallback ? "--fallback-icon" : "--icon", icon.path] }
        return arguments
    }

    /// The engine's language code for the user's language: "it", "en-GB", "zh-Hans"; nil = the engine's default.
    public static func language(for locale: Locale = .current) -> String? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        switch code {
        case "en": return nil
        case "zh": return locale.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
        case "pt": return locale.region?.identifier == "BR" ? "pt-BR" : "pt"
        case "ja", "fr", "de", "es", "it", "nl", "ru", "ko": return code
        default: return nil
        }
    }

    /// A build stopped only because the game lacks the user's language: build again in the engine's default.
    public static func failedOnLanguage(_ state: NXBuildState) -> Bool {
        state.warnings.contains { $0.contains("the game has no") && $0.contains("--language") }
    }
}
