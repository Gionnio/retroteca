import Foundation
import AppKit
import RetrotecaCore

/// Switch and Switch 2 games built into Mac apps on this Mac, with the user's own files and keys.
/// Retroteca is a front end of the engine (nxnative's docs/frontends.md): it never downloads a built game.
@MainActor
final class SwitchManager: ObservableObject {
    let catalog: NativeEngineCatalog
    let paths = NXPaths.standard
    @Published private(set) var toolchain: NXToolchain?
    @Published private(set) var profiles: [NXProfile] = []
    /// Tools being installed: the step shown in the capsule and on the game page.
    @Published private(set) var setupText: String?
    @Published private(set) var setupError: String?
    /// The game being built, and every build's last state (kept after the end for the build screen).
    @Published private(set) var buildingID: UUID?
    @Published private(set) var builds: [UUID: NXBuildState] = [:]
    @Published private(set) var buildErrors: [UUID: String] = [:]
    @Published private(set) var buildStarted: [UUID: Date] = [:]
    /// Values Retroteca recommends per game, and the engine's documented switches they are checked against.
    @Published private(set) var tweaks: GameTweaksCatalog?
    @Published private(set) var envSwitches: [String: String] = [:]

    /// Called when a build made an app: the library records it.
    var onBuilt: ((UUID, URL, NXBuildState) -> Void)?
    /// Called when a build ends, however it ended (the queue starts the next one).
    var onFinished: ((UUID, BuildOutcome) -> Void)?

    enum BuildOutcome: Equatable {
        case built
        case cancelled
        case failed(String)
    }
    /// Called when the engine's game profiles were (re)loaded.
    var onProfiles: (() -> Void)?

    private var process: Process?
    private var cancelled = false
    private let brew: BrewRunner?

    init() {
        if let url = Bundle.main.url(forResource: "native-engines", withExtension: "json"), let loaded = try? NativeEngineCatalog.load(from: url) {
            catalog = loaded
        } else {
            catalog = NativeEngineCatalog(engines: [])
        }
        brew = BrewRunner.findBrew().map { url in
            BrewRunner(brewURL: url, passwordPromptScript: BrewRunner.installPasswordPrompt(
                in: ActivityLog.directory, message: String(localized: "Retroteca deve installare gli strumenti per costruire i giochi Switch.")))
        }
        // What earlier builds left behind: tens of GB per game after an engine update.
        let folders = paths.allObsolete()
        Task.detached { await Self.removeObsolete(folders) }
    }

    /// Deletes the engine's obsolete folders, never the one of a build still running (even one a previous Retroteca started).
    nonisolated static func removeObsolete(_ folders: [URL]) async {
        guard !folders.isEmpty else { return }
        let running = runningCommands()
        var freed: Int64 = 0
        for folder in folders where !running.contains(folder.deletingLastPathComponent().path) {
            let size = allocatedSize(folder)
            if (try? FileManager.default.removeItem(at: folder)) != nil { freed += size }
        }
        if freed > 0 { ActivityLog.write("Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of files earlier builds no longer use") }
    }

    nonisolated private static func runningCommands() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func allocatedSize(_ folder: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// The engine at the commit Retroteca was tested with, or at the one the user moved to (a newer upstream commit,
    /// or a channel's branch such as the fork for M1 and M2 Macs).
    var engine: NativeEngine? {
        guard let base = catalog.engine(for: "switch") else { return nil }
        guard let moved = engineOverride, moved.commit != base.commit || moved.repo != nil else { return base }
        return base.at(commit: moved.commit, committedAt: moved.date, repo: moved.repo)
    }

    /// The engine as Retroteca tested it.
    var testedEngine: NativeEngine? { catalog.engine(for: "switch") }

    /// The channel in use; nil = upstream.
    var channel: NativeEngine.Channel? {
        guard let id = engineOverride?.channel else { return nil }
        return testedEngine?.channels?.first { $0.id == id }
    }

    // MARK: Engine updates and channels

    struct EngineOverride: Codable, Equatable {
        let commit: String
        let date: String?
        /// The fork a channel builds from, and the channel's id; nil for upstream.
        var repo: String? = nil
        var channel: String? = nil
    }

    /// A commit the user chose (kept across launches); nil = the tested one.
    @Published private(set) var engineOverride: EngineOverride? = UserDefaults.standard.data(forKey: "engineOverride.nxnative")
        .flatMap { try? JSONDecoder().decode(EngineOverride.self, from: $0) }
    @Published private(set) var engineUpdate: NXEngineUpdate?
    @Published private(set) var checkingEngine = false

    private func githubData(_ repo: String, _ path: String) async -> Data? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Retroteca", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The head commit of a branch and its date ("2026-11-12").
    private func branchHead(_ repo: String, _ branch: String) async -> (sha: String, date: String?)? {
        guard let data = await githubData(repo, "branches/\(branch)"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let head = object["commit"] as? [String: Any], let sha = head["sha"] as? String else { return nil }
        let date = ((head["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"] as? String
        return (sha, date.map { String($0.prefix(10)) })
    }

    private func saveOverride(_ value: EngineOverride?) {
        if let value { UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "engineOverride.nxnative") }
        else { UserDefaults.standard.removeObject(forKey: "engineOverride.nxnative") }
        engineOverride = value
    }

    /// Asks GitHub what the branch in use (upstream main, or the channel's) has after the commit in use.
    /// `games` are the user's Switch games, by the engine's names.
    func checkEngineUpdate(games: [String]) async {
        guard let engine, !checkingEngine else { return }
        checkingEngine = true
        defer { checkingEngine = false }
        let branch = channel?.branch ?? "main"
        guard let head = await branchHead(engine.repo, branch) else { return }
        UserDefaults.standard.set(Date(), forKey: "engineCheckedAt")
        guard head.sha != engine.commit else { engineUpdate = nil; return }
        let compareURL = URL(string: "https://github.com/\(engine.repo)/compare/\(engine.commit)...\(head.sha)")!
        if let compare = await githubData(engine.repo, "compare/\(engine.commit)...\(head.sha)"),
           let update = NXEngineUpdate.parse(compare: compare, engine: engine, latest: head.sha, latestDate: head.date, games: games) {
            engineUpdate = update
        } else {
            // A channel's branch is rebuilt on upstream each time: the old commit may not be an ancestor any more.
            engineUpdate = NXEngineUpdate(latest: head.sha, latestDate: head.date, count: 0, gameMentions: [:],
                                          contractChanged: false, requirementsChanged: true, shadersChanged: true, compareURL: compareURL)
        }
    }

    /// Moves the engine to the latest commit of its branch; the games show a rebuild.
    func updateEngine() async {
        guard let update = engineUpdate, !isBusy else { return }
        saveOverride(EngineOverride(commit: update.latest, date: update.latestDate, repo: engineOverride?.repo, channel: engineOverride?.channel))
        if update.requirementsChanged { try? FileManager.default.removeItem(at: paths.venv.appendingPathComponent(".retroteca-ready")) }
        ActivityLog.write("Engine moved to nxnative \(update.latest.prefix(8))\(channel.map { " (\($0.name))" } ?? "") (\(update.count) commits after the previous one)")
        engineUpdate = nil
        await prepareTools()
    }

    /// Builds from a channel's branch (its latest commit), or back to upstream's tested commit with nil.
    func selectChannel(_ id: String?) async {
        guard !isBusy, id != engineOverride?.channel else { return }
        guard let id else { await useTestedEngine(); return }
        guard let channel = testedEngine?.channels?.first(where: { $0.id == id }) else { return }
        checkingEngine = true
        let head = await branchHead(channel.repo, channel.branch)
        checkingEngine = false
        guard let head else {
            setupError = String(localized: "GitHub non risponde: il canale \(channel.name) non è raggiungibile ora.")
            return
        }
        saveOverride(EngineOverride(commit: head.sha, date: head.date, repo: channel.repo, channel: channel.id))
        // The fork may pin other Python tools than the commit in use: set the environment up again.
        try? FileManager.default.removeItem(at: paths.venv.appendingPathComponent(".retroteca-ready"))
        ActivityLog.write("Engine channel: \(channel.name), \(channel.repo)@\(head.sha.prefix(8))")
        engineUpdate = nil
        await prepareTools()
    }

    /// Back to the commit Retroteca tested, on upstream.
    func useTestedEngine() async {
        guard engineOverride != nil, !isBusy else { return }
        saveOverride(nil)
        try? FileManager.default.removeItem(at: paths.venv.appendingPathComponent(".retroteca-ready"))
        ActivityLog.write("Engine back to the tested nxnative \(testedEngine?.shortCommit ?? "")")
        engineUpdate = nil
        await prepareTools()
    }

    // MARK: Recommended settings

    private static let tweaksURL = URL(string: "https://raw.githubusercontent.com/Gionnio/retroteca/main/catalog/game-tweaks.json")!
    private var tweaksCache: URL { paths.root.deletingLastPathComponent().appendingPathComponent("game-tweaks.json") }

    /// The copy in the app, or a newer one saved from the project's repository; the repository is asked at most once a day.
    func loadTweaks() {
        let bundled = Bundle.main.url(forResource: "game-tweaks", withExtension: "json").flatMap { try? GameTweaksCatalog.load(from: $0) }
        tweaks = GameTweaksCatalog.newest(bundled, try? GameTweaksCatalog.load(from: tweaksCache))
        let checked = UserDefaults.standard.object(forKey: "gameTweaksCheckedAt") as? Date
        guard checked.map({ Date().timeIntervalSince($0) > 86400 }) ?? true else { return }
        let cache = tweaksCache
        Task {
            var request = URLRequest(url: Self.tweaksURL, timeoutInterval: 20)
            request.setValue("Retroteca", forHTTPHeaderField: "User-Agent")
            UserDefaults.standard.set(Date(), forKey: "gameTweaksCheckedAt")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let remote = try? JSONDecoder().decode(GameTweaksCatalog.self, from: data),
                  GameTweaksCatalog.newest(tweaks, remote) == remote, remote != tweaks else { return }
            try? data.write(to: cache, options: .atomic)
            tweaks = remote
            ActivityLog.write("Recommended settings updated to \(remote.version)")
        }
    }
    var isBusy: Bool { setupText != nil || buildingID != nil }
    var hasHomebrew: Bool { brew != nil }

    // MARK: Tools

    func refresh() {
        guard let engine else { return }
        let paths = paths, brewURL = brew?.brewURL
        Task.detached {
            let toolchain = NXToolchain.check(engine, paths: paths, brew: brewURL)
            let profiles = Self.loadProfiles(engine: engine, paths: paths)
            let switches = (try? String(contentsOf: paths.engine.appendingPathComponent("docs/env_switches.tsv"), encoding: .utf8)).map(GameTweaks.envSwitches) ?? [:]
            await MainActor.run {
                self.envSwitches = switches
                self.toolchain = toolchain
                if !profiles.isEmpty, profiles != self.profiles { self.profiles = profiles; self.onProfiles?() }
            }
        }
    }

    nonisolated static func loadProfiles(engine: NativeEngine, paths: NXPaths) -> [NXProfile] {
        let python = FileManager.default.isExecutableFile(atPath: paths.python.path) ? paths.python : NXToolchain.pythonExecutable(engine)
        guard let python, FileManager.default.fileExists(atPath: paths.engine.appendingPathComponent("dm/games/game.py").path) else { return [] }
        let process = Process()
        process.executableURL = python
        process.arguments = [paths.engine.appendingPathComponent("dm/games/game.py").path, "list"]
        process.currentDirectoryURL = paths.engine
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var profiles = NXProfile.parseList(text)
        if let readme = try? String(contentsOf: paths.engine.appendingPathComponent("\(engine.profiles)/README.md"), encoding: .utf8) {
            let builds = NXProfile.parseBuilds(readme: readme)
            for i in profiles.indices { profiles[i].builds = builds[profiles[i].titleID] }
        }
        return profiles
    }

    /// Installs what Retroteca can install by itself: Homebrew packages, the engine at its pinned commit, the Python environment.
    func prepareTools() async {
        guard let engine, setupText == nil else { return }
        setupError = nil
        let log = ActivityLog.directory.appendingPathComponent("switch-setup.log")
        ActivityLog.write("Preparing Switch tools (\(engine.name) \(engine.shortCommit))")
        var toolchain = NXToolchain.check(engine, paths: paths, brew: brew?.brewURL)
        do {
            if let brew, !toolchain.missingFormulas.isEmpty || toolchain.missing[.python] != nil {
                let formulas = toolchain.missingFormulas + (toolchain.missing[.python] != nil ? ["python@\(engine.requires.python)"] : [])
                setupText = String(localized: "Installo \(formulas.joined(separator: ", ")) con Homebrew…")
                let output = await brew.run(["install"] + formulas, watchdog: BrewWatchdog(timeout: 600))
                Self.append(output.text, to: log)
                guard output.succeeded else { throw SetupFailure(String(localized: "Homebrew non ha installato \(formulas.joined(separator: ", ")).")) }
            }
            if let brew, !toolchain.missingCasks.isEmpty {
                setupText = String(localized: "Installo .NET SDK con Homebrew (chiede la password)…")
                let output = await brew.run(["install", "--cask"] + toolchain.missingCasks, watchdog: BrewWatchdog(timeout: 900))
                Self.append(output.text, to: log)
                guard output.succeeded else { throw SetupFailure(String(localized: "Homebrew non ha installato .NET SDK.")) }
            }
            if toolchain.missing[.engine] != nil {
                setupText = String(localized: "Scarico \(engine.name) \(engine.shortCommit) da GitHub…")
                try await Self.fetchEngine(engine, paths: paths, log: log)
            }
            toolchain = NXToolchain.check(engine, paths: paths, brew: brew?.brewURL)
            if toolchain.missing[.venv] != nil {
                setupText = String(localized: "Preparo l'ambiente Python…")
                try await Self.makeEnvironment(engine, paths: paths, log: log)
            }
            ActivityLog.write("Switch tools ready")
        } catch {
            setupError = error.localizedDescription
            ActivityLog.write("Switch tools failed: \(error.localizedDescription)")
        }
        setupText = nil
        refresh()
    }

    struct SetupFailure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    /// A clone without history beyond what the pinned commit needs, checked out at that commit.
    nonisolated static func fetchEngine(_ engine: NativeEngine, paths: NXPaths, log: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: paths.engine.appendingPathComponent(".git").path) {
            if fm.fileExists(atPath: paths.engine.path) { try fm.removeItem(at: paths.engine) }
            try await runLogged("/usr/bin/git", ["clone", "--filter=blob:none", "--no-checkout", engine.repoURL.absoluteString + ".git", paths.engine.path], log: log)
        }
        // From the repository of the commit in use: upstream, or a channel's fork (the checkout's origin stays upstream).
        try await runLogged("/usr/bin/git", ["-C", paths.engine.path, "fetch", "--filter=blob:none", engine.repoURL.absoluteString + ".git", engine.commit], log: log)
        try await runLogged("/usr/bin/git", ["-C", paths.engine.path, "checkout", "--force", "--detach", engine.commit], log: log)
    }

    nonisolated static func makeEnvironment(_ engine: NativeEngine, paths: NXPaths, log: URL) async throws {
        guard let python = NXToolchain.pythonExecutable(engine) else { throw SetupFailure(String(localized: "Manca Python \(engine.requires.python).")) }
        if !FileManager.default.isExecutableFile(atPath: paths.python.path) {
            try await runLogged(python.path, ["-m", "venv", paths.venv.path], log: log)
        }
        try await runLogged(paths.venv.appendingPathComponent("bin/pip").path,
                            ["install", "--disable-pip-version-check", "-r", paths.engine.appendingPathComponent(engine.requires.pythonRequirements).path], log: log)
        FileManager.default.createFile(atPath: paths.venv.appendingPathComponent(".retroteca-ready").path, contents: Data(engine.commit.utf8))
    }

    nonisolated static func runLogged(_ tool: String, _ arguments: [String], log: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.environment = buildEnvironment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let collected = LockedText()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collected.append(String(decoding: data, as: UTF8.self)) }
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let text = collected.value
                append("$ \((tool as NSString).lastPathComponent) \(arguments.joined(separator: " "))\n" + text, to: log)
                if process.terminationStatus == 0 { continuation.resume() } else {
                    continuation.resume(throwing: SetupFailure("\((tool as NSString).lastPathComponent): \(text.suffix(300))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// GUI apps start with a bare PATH: the engine's tools live in Homebrew.
    nonisolated static func buildEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    nonisolated static func append(_ text: String, to url: URL) {
        let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Keys

    func importKeys(from url: URL) throws {
        try NXKeys.importKeys(from: url, to: paths.keys)
        ActivityLog.write("Console keys imported (private copy, 0600)")
        refresh()
    }

    var existingKeys: [URL] { NXKeys.existingCandidates() }

    // MARK: Games

    func profile(for game: Game) -> NXProfile? {
        NXProfile.match(titleID: game.titleID, title: game.title, in: profiles)
    }

    /// Where the app of this game goes: "The Legend of Zelda - Tears of the Kingdom.app".
    func appURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: ": ", with: " - ").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return NXPaths.appsFolder.appendingPathComponent(safe + ".app")
    }

    /// Bytes the first build needs: about twice the game plus 10 GB (the engine's own estimate); much less once the work folder exists.
    func spaceNeeded(for game: Game) -> Int64 {
        let id = game.titleID ?? "unknown"
        if FileManager.default.fileExists(atPath: paths.work(id).appendingPathComponent("extract").path) { return 5 << 30 }
        return game.size * 2 + (10 << 30)
    }

    /// Free space on the disk the games are built on.
    var freeSpace: Int64 {
        DiskSpace.free(at: GamesLocation.volume ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// A paused build is not an error.
    func clearError(_ gameID: UUID) { buildErrors[gameID] = nil }

    func cancel() {
        guard let process, process.isRunning else { return }
        cancelled = true
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    /// Builds the game into a Mac app. The engine reads links to the user's files; nothing is copied.
    /// The version each game's last build packed.
    private(set) var lastPackage: [UUID: Int] = [:]
    private var versionCache: [String: NXProfileVersions] = [:]

    func versions(for titleID: String) -> NXProfileVersions {
        if let cached = versionCache[titleID] { return cached }
        guard let engine else { return NXProfileVersions() }
        let versions = NXProfileVersions.load(engineRoot: paths.engine, profiles: engine.profiles, titleID: titleID)
        versionCache[titleID] = versions
        return versions
    }

    func build(_ game: Game, language: String? = NXBuildCommand.language(), package: Int? = nil) {
        guard let engine, buildingID == nil, let titleID = game.titleID ?? profile(for: game)?.titleID else {
            if game.titleID == nil && profile(for: game) == nil { buildErrors[game.id] = String(localized: "Non so ancora quale gioco è: aggiungi il file con l'ID del titolo nel nome.") }
            return
        }
        buildErrors[game.id] = nil
        let fm = FileManager.default
        if !GamesLocation.isAvailable, let disk = GamesLocation.volume?.lastPathComponent {
            buildErrors[game.id] = String(localized: "Collega \(disk), o scegli Questo Mac nella pagina Spazio.")
            return
        }
        // A build that would leave the disk below the user's margin does not start.
        let needed = spaceNeeded(for: game), free = freeSpace, margin = SpaceSettings.keepFree
        if free - needed < margin {
            let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
            buildErrors[game.id] = String(localized: "Spazio insufficiente: servono circa \(bytes(needed)) più \(bytes(margin)) di margine, liberi \(bytes(free)).")
            return
        }
        // Files on a disk or NAS that is not connected: say so before the engine starts.
        if let missing = game.files.first(where: { !fm.fileExists(atPath: $0.path) }) {
            buildErrors[game.id] = String(localized: "Non trovo i file del gioco (\(missing.deletingLastPathComponent().path)): collega il disco o il NAS e riprova.")
            return
        }
        do {
            let input = paths.input(titleID)
            if fm.fileExists(atPath: input.path) { try fm.removeItem(at: input) }
            try fm.createDirectory(at: input, withIntermediateDirectories: true)
            for file in game.files {
                try fm.createSymbolicLink(at: input.appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
            }
            try fm.createDirectory(at: paths.work(titleID), withIntermediateDirectories: true)
            try fm.createDirectory(at: NXPaths.appsFolder, withIntermediateDirectories: true)
        } catch {
            buildErrors[game.id] = error.localizedDescription
            return
        }
        // A rebuild replaces the app where new apps go now; one built elsewhere by Retroteca is removed once the new one is ready.
        let output = game.nativeApp.flatMap { $0.path.hasPrefix(NXPaths.appsFolder.path + "/") ? $0 : nil } ?? appURL(for: profile(for: game)?.name ?? game.title)
        let needsKeys = !game.files.allSatisfy { $0.pathExtension.lowercased() == "nup" }
        // A NUP often has no icon of its own: the store's square art stands in.
        let icon = needsKeys ? nil : game.coverURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let script = (try? String(contentsOf: paths.engine.appendingPathComponent(engine.script), encoding: .utf8)) ?? ""
        let arguments = NXBuildCommand.arguments(engine: engine, paths: paths, titleID: titleID, output: output, language: language,
                                                 needsKeys: needsKeys, package: package, icon: icon,
                                                 iconIsFallback: script.contains("--fallback-icon"))
        lastPackage[game.id] = package
        // A rebuild replaces the app: the save is copied first (it lives outside the app and normally carries over).
        if game.nativeApp != nil {
            let saves = NXSaves(folder: NXGameFolder(titleID: titleID), backups: paths.root.appendingPathComponent("SaveBackups/\(titleID)", isDirectory: true))
            if saves.hasSave { _ = try? saves.backUp(note: "before rebuild") }
        }
        let logURL = ActivityLog.directory.appendingPathComponent("switch-\(titleID).log")
        try? Data().write(to: logURL)
        Self.append("Retroteca build of \(game.title) with \(engine.name) \(engine.shortCommit)\n$ python3 \(arguments.joined(separator: " "))", to: logURL)

        let process = Process()
        process.executableURL = paths.python
        process.arguments = arguments
        process.currentDirectoryURL = paths.engine
        process.environment = Self.buildEnvironment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let lines = LineSplitter()
        let errors = LockedText()
        let gameID = game.id
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Self.append(String(decoding: data, as: UTF8.self), to: logURL)
            let events = lines.feed(data).compactMap(NXEvent.parse)
            guard !events.isEmpty else { return }
            Task { @MainActor in
                var state = self.builds[gameID] ?? NXBuildState()
                for event in events { state.apply(event) }
                self.builds[gameID] = state
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errors.append(String(decoding: data, as: UTF8.self))
            Self.append(String(decoding: data, as: UTF8.self), to: logURL)
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self.finish(gameID: gameID, game: game, status: status, stderr: errors.value, output: output, language: language)
            }
        }
        builds[game.id] = NXBuildState()
        buildStarted[game.id] = Date()
        BuildNotifier.requestPermission()
        buildingID = game.id
        cancelled = false
        self.process = process
        ActivityLog.write("Building \(game.title) (\(titleID)) with \(engine.name) \(engine.shortCommit)")
        do { try process.run() } catch {
            buildingID = nil
            buildErrors[game.id] = error.localizedDescription
        }
    }

    private func finish(gameID: UUID, game: Game, status: Int32, stderr: String, output: URL, language: String?) {
        process = nil
        buildingID = nil
        let state = builds[gameID] ?? NXBuildState()
        let elapsed = buildStarted[gameID].map { Date().timeIntervalSince($0) } ?? 0
        if status == 0, FileManager.default.fileExists(atPath: output.path) {
            ActivityLog.write("Built \(game.title) in \(Int(elapsed / 60)) min: \(output.path)")
            if let titleID = game.titleID ?? profile(for: game)?.titleID {
                if SpaceSettings.compact {
                    // Compact: the caches go as soon as the app is ready; the next build starts from scratch.
                    let folder = paths.work(titleID), title = game.title
                    Task.detached {
                        let freed = BuildFolder.freeCaches(folder)
                        ActivityLog.write("Compact: freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of \(title)'s build caches")
                    }
                } else {
                    let folder = paths.obsolete(titleID)
                    Task.detached { await Self.removeObsolete([folder]) }
                }
            }
            onBuilt?(gameID, output, state)
            onFinished?(gameID, .built)
            return
        }
        // 130 interrupted, 143 stopped by SIGTERM (a cancel), 129 its terminal closed.
        if cancelled || [129, 130, 143].contains(status) {
            buildErrors[gameID] = String(localized: "Costruzione annullata.")
            ActivityLog.write("Build of \(game.title) cancelled")
            onFinished?(gameID, .cancelled)
            return
        }
        if language != nil, NXBuildCommand.failedOnLanguage(state) {
            ActivityLog.write("\(game.title) lacks the user's language: building again in the game's default")
            build(game, language: nil, package: lastPackage[gameID])
            return
        }
        let reason = state.lastError ?? stderr.split(separator: "\n").last.map(String.init) ?? String(localized: "uscita \(status)")
        buildErrors[gameID] = reason
        BuildNotifier.post(title: String(localized: "\(game.title): costruzione interrotta"), body: reason)
        ActivityLog.write("Build of \(game.title) failed (\(status)): \(reason)")
        onFinished?(gameID, .failed(reason))
    }

    func logURL(for game: Game) -> URL? {
        guard let id = game.titleID ?? profile(for: game)?.titleID else { return nil }
        return ActivityLog.directory.appendingPathComponent("switch-\(id).log")
    }
}

/// Text collected from a process's pipe on its reading thread.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ more: String) { lock.withLock { text += more; if text.count > 200_000 { text = String(text.suffix(100_000)) } } }
    var value: String { lock.withLock { text } }
}

/// Splits a byte stream into whole lines (a JSON event may arrive in two reads).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func feed(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }
}
