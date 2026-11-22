import SwiftUI
import AppKit
import OSLog
import Combine
import UniformTypeIdentifiers
import RetrotecaCore

let log = Logger(subsystem: "com.github.gionnio.Retroteca", category: "app")

/// The page shown in the window. Every page is in the Platea style.
enum Page: Hashable {
    case vetrina
    case grid
    case game(UUID)
    /// The engine that builds the games, its updates and tools.
    case engines
    /// The build screen of a Switch game.
    case build(UUID)
    /// A Switch game's options: settings, mods, cheats, saves.
    case options(UUID)
    /// What Retroteca takes on disk, and freeing it.
    case space
}

/// State of the main window: library, selection, search, last message.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var page: Page = .vetrina
    /// Pages to go back to (game, build, options and space pages).
    private var history: [Page] = []
    /// The game shown in the Vetrina hero (focused tile).
    @Published var heroID: UUID?
    @Published var selection: UUID?
    /// The game being played, while its app runs.
    @Published private(set) var runningGameID: UUID?
    @Published var searchText = ""
    @Published var isImporting = false
    @Published var message: String?
    /// The Switch game whose app is opening: the launch screen shows until its window takes over.
    @Published private(set) var launchingGameID: UUID?

    let catalog: PlatformCatalog
    let switchGames = SwitchManager()
    /// Moves and actions from the keyboard or a controller, for the page on screen.
    let navigation = PassthroughSubject<NavCommand, Never>()
    let gamepads = GamepadNavigator()
    private let store: LibraryStore
    private var terminationObserver: NSObjectProtocol?
    private var switchChanges: AnyCancellable?
    private var spaceChanges: AnyCancellable?
    lazy var space = SpaceManager(root: libraryLocation)
    private var gamepadChanges: AnyCancellable?
    private var switchInfoCache: [URL: SwitchFileInfo] = [:]

    init(store: LibraryStore = LibraryStore(fileURL: LibraryStore.defaultDirectory.appendingPathComponent("library.json")),
         catalog: PlatformCatalog = AppModel.loadCatalog()) {
        self.store = store
        self.catalog = catalog
        do {
            try store.load()
        } catch {
            log.error("Library not readable: \(error.localizedDescription, privacy: .public)")
            message = String(localized: "La libreria non si legge: \(error.localizedDescription)")
        }
        if UserDefaults.standard.object(forKey: "checkFilesAtLaunch") as? Bool ?? true {
            store.refreshFileStatus()
        }
        // Retroteca plays Switch and Switch 2 games only: entries of other systems from earlier versions leave the library
        // (their files stay where they are).
        let others = store.games.filter { $0.kind != .switchNative }
        if !others.isEmpty {
            store.remove(ids: Set(others.map(\.id)))
            try? store.save()
            ActivityLog.write("Took \(others.count) entries of other systems out of the library; no file deleted")
        }
        games = store.games
        applyEngineStatus()
        // Views read engine state through the model: forward its changes.
        switchChanges = switchGames.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        switchGames.onBuilt = { [weak self] id, app, state in self?.recordBuild(id, app: app, state: state) }
        switchGames.onProfiles = { [weak self] in self?.organizeSwitchGames() }
        gamepadChanges = gamepads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        spaceChanges = space.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        gamepads.send = { [weak self] command in self?.navigate(command) }
        gamepads.announce = { [weak self] text in self?.message = text }
        gamepads.start()
        switchGames.refresh()
        switchGames.loadTweaks()
        adoptNativeApps()
        organizeSwitchGames()
        fetchSwitchMetadata()
    }

    nonisolated static func loadCatalog() -> PlatformCatalog {
        guard let url = Bundle.main.url(forResource: "platforms", withExtension: "json"),
              let catalog = try? PlatformCatalog.load(from: url) else {
            log.error("platforms.json missing from the app bundle")
            return PlatformCatalog(platforms: [])
        }
        return catalog
    }

    var libraryLocation: URL { store.fileURL.deletingLastPathComponent() }

    // MARK: Derived

    /// What opens the game: its Mac app, or the engine that will build it.
    func runnerName(for game: Game) -> String? {
        guard let engine = switchGames.engine else { return nil }
        return game.nativeApp != nil ? String(localized: "App Mac nativa · \(engine.name)") : String(localized: "Da costruire con \(engine.name)")
    }

    func game(id: UUID) -> Game? { games.first { $0.id == id } }

    /// Top pages (pills) start a new history; detail pages remember where they came from.
    func open(_ page: Page) {
        guard page != self.page else { return }
        (page.isDetail ? InterfaceSound.select : InterfaceSound.page).play()
        if page.isDetail { history.append(self.page) } else { history.removeAll() }
        if case .game(let id) = page { selection = id }
        self.page = page
    }

    func back() {
        InterfaceSound.back.play()
        page = history.popLast() ?? .vetrina
    }

    func closeGamePage() { back() }


    func count(status: GameStatus) -> Int { games.count(status: status) }

    var platformIDs: [String] { games.platformIDs(in: catalog) }

    func platformName(_ id: String?) -> String {
        guard let id else { return String(localized: "Console da riconoscere") }
        return catalog.platform(id: id)?.name ?? id
    }

    // MARK: Actions

    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let catalog = self.catalog
        // Off by default: Retroteca does not duplicate games, it remembers where they are.
        let copyDestination = UserDefaults.standard.bool(forKey: "copyGamesToLibrary") ? libraryLocation.appendingPathComponent("Games", isDirectory: true) : nil
        Task.detached(priority: .userInitiated) {
            let imported = Importer(catalog: catalog).games(from: urls).filter { $0.kind == .switchNative }
            let (found, copyFailures) = copyDestination.map { GameCopier(destination: $0).copy(imported) } ?? (imported, [])
            for failure in copyFailures { log.error("Copy failed: \(failure, privacy: .public)") }
            await MainActor.run {
                let added = self.store.add(found)
                self.persist()
                self.isImporting = false
                if added.isEmpty {
                    self.message = found.isEmpty
                        ? String(localized: "Nessun gioco Switch nei file trascinati.")
                        : String(localized: "Questi giochi sono già in libreria.")
                } else {
                    self.organizeSwitchGames()
                    self.fetchSwitchMetadata()
                    self.message = copyFailures.isEmpty
                        ? (added.count == 1 ? String(localized: "1 gioco aggiunto.") : String(localized: "\(added.count) giochi aggiunti."))
                        : String(localized: "\(added.count) giochi aggiunti; \(copyFailures.count) non copiati, restano dove sono.")
                    self.selection = added.first?.id
                }
                log.info("Imported \(added.count) of \(found.count) games")
            }
        }
    }

    /// A Switch game is ready once its app is built.
    func applyEngineStatus() {
        for game in store.games where game.kind == .switchNative {
            var updated = game
            // An app on a disk that is not connected stays built: it plays again once the disk is back.
            let built = game.nativeApp.map { FileManager.default.fileExists(atPath: $0.path) || GamesLocation.missingVolume(of: $0) != nil } ?? false
            if game.status != .missingFiles || built { updated.status = built ? .ready : .needsEngine }
            if updated.status != game.status { store.update(updated) }
        }
        persist()
    }

    func play(_ game: Game) {
        guard runningGameID == nil else {
            message = String(localized: "C'è già un gioco aperto.")
            return
        }
        do {
            if let app = game.nativeApp, let disk = GamesLocation.missingVolume(of: app) {
                message = String(localized: "Collega \(disk) per giocare.")
                return
            }
            guard let app = game.nativeApp, FileManager.default.fileExists(atPath: app.path) else {
                open(.game(game.id))
                message = String(localized: "Costruisci prima il gioco.")
                return
            }
            InterfaceSound.launch.play()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // The choices are made in Retroteca's Options: skip the app's own window, unless ⌥ is held.
            var environment: [String: String] = [:]
            if !NSEvent.modifierFlags.contains(.option) { environment["DM_LAUNCHER"] = "0" }
            environment["DM_HOME_QUIT_TEXT"] = [String(localized: "Tieni premuto per uscire"), String(localized: "Uscire da \(game.title)?"),
                                               String(localized: "I progressi non salvati andranno persi."), String(localized: "Esci"), String(localized: "Annulla")].joined(separator: "\n")
            if gamepads.unlistedProController {
                environment["DM_PAD_IDENTICAL"] = "0"
                ActivityLog.write("\(game.title): Pro Controller not listed by macOS, pad twins off (DM_PAD_IDENTICAL=0)")
            }
            configuration.environment = environment
            let started = Date()
            launchingGameID = game.id
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
                Task { @MainActor in
                    if let error {
                        self.launchingGameID = nil
                        self.message = String(localized: "\(game.title) non si è avviato: \(error.localizedDescription)")
                        return
                    }
                    guard let running else { self.launchingGameID = nil; return }
                    self.runningGameID = game.id
                    self.launchingApp = running
                    ActivityLog.write("Playing \(game.title) (native Mac build)")
                    self.watchTermination(of: running, gameID: game.id, started: started)
                    // The game's window takes over: Retroteca stops being the active app. At most 30 s of launch screen.
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if self.launchingGameID == game.id { self.launchingGameID = nil }
                }
            }
            return
        }
    }

    // MARK: Navigation

    /// A screenshot is open over the game page: B, L and R go to it instead of leaving the page.
    @Published var viewerOpen = false

    /// Pills of the top bar, in order: LB and RB walk through them.
    private var topPages: [Page] { [.vetrina, .grid, .engines] }

    /// A command from a controller (or a key the pages leave to the app): global ones here, the rest to the page on screen.
    func navigate(_ command: NavCommand) {
        switch command {
        case .back:
            if viewerOpen { navigation.send(.back) } else if launchingGameID != nil { cancelLaunch() } else if page.isDetail { back() }
        case .previousPage, .nextPage:
            // A screenshot open over the page: L and R walk the screenshots instead of the pills.
            if viewerOpen { navigation.send(command); return }
            let current = topPages.firstIndex(of: page) ?? 0
            let next = (current + (command == .nextPage ? 1 : -1) + topPages.count) % topPages.count
            open(topPages[next])
        case .menu:
            NSApp.keyWindow?.toggleFullScreen(nil)
        default:
            navigation.send(command)
        }
    }

    /// What A or Return does on a game: play it, or the step that makes it playable.
    func primaryAction(for game: Game) {
        if game.nativeApp != nil { play(game) }
        else if switchGames.buildingID == game.id { open(.build(game.id)) }
        else if switchGames.toolchain?.isReady == true, game.status != .missingFiles, switchHasBase(game) { buildSwitchGame(game) }
        else { open(.game(game.id)) }
    }

    /// The game's app while the launch screen shows (Esc stops it).
    private var launchingApp: NSRunningApplication?

    /// Called when Retroteca stops being the active app: the game's window is up.
    func gameWindowAppeared() {
        guard launchingGameID != nil else { return }
        launchingGameID = nil
        launchingApp = nil
    }

    func cancelLaunch() {
        launchingApp?.terminate()
        launchingApp = nil
        launchingGameID = nil
    }

    private func watchTermination(of app: NSRunningApplication, gameID: UUID, started: Date) {
        let pid = app.processIdentifier
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ended.processIdentifier == pid else { return }
            Task { @MainActor in
                guard let self else { return }
                if let observer = self.terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
                self.terminationObserver = nil
                self.runningGameID = nil
                self.launchingGameID = nil
                self.store.recordPlay(id: gameID, started: started, ended: Date())
                self.persist()
                self.message = String(localized: "Partita salvata nel tempo di gioco.")
            }
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.isFavorite.toggle()
        store.update(game)
        persist()
    }

    func remove(_ id: UUID) {
        if let game = games.first(where: { $0.id == id }) { forgetArtworkAndApp(of: game) }
        store.remove(ids: [id])
        if selection == id { selection = nil }
        persist()
        message = String(localized: "Gioco tolto dalla libreria.")
    }

    /// Deletes the app Retroteca built for a game (never one another front end made); the game stays, to build again.
    func deleteNativeApp(_ id: UUID) {
        guard var game = store.games.first(where: { $0.id == id }), let app = game.nativeApp,
              GamesLocation.isRetrotecaApp(app) else { return }
        try? FileManager.default.removeItem(at: app)
        game.nativeApp = nil
        game.builtFiles = nil
        game.builtVersion = nil
        game.builtEngine = nil
        store.update(game)
        games = store.games
        persist()
        applyEngineStatus()
        ActivityLog.write("Deleted the app of \(game.title): \(app.path)")
    }

    /// Empties the library: every entry goes, the games' files and the built apps stay where they are.
    func emptyLibrary() {
        let all = store.games
        all.forEach(forgetArtworkAndApp)
        store.remove(ids: Set(all.map(\.id)))
        selection = nil
        heroID = nil
        persist()
        open(.vetrina)
        message = String(localized: "Libreria svuotata: \(all.count) giochi tolti.")
        ActivityLog.write("Library emptied (\(all.count) entries); no file deleted")
    }

    /// Downloaded artwork belongs to Retroteca and goes with the entry; a Mac app found on disk is not added back on its own.
    private func forgetArtworkAndApp(of game: Game) {
        for url in [game.coverURL, game.backdropURL, game.logoURL].compactMap({ $0 }) + (game.screenshots ?? []) where url.path.hasPrefix(libraryLocation.path) {
            try? FileManager.default.removeItem(at: url)
        }
        if game.kind == .switchNative, game.nativeApp != nil, let titleID = game.titleID {
            var ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredNativeApps") ?? [])
            ignored.insert(titleID)
            UserDefaults.standard.set(Array(ignored), forKey: "ignoredNativeApps")
        }
    }

    func refreshFiles() {
        store.refreshFileStatus()
        persist()
        message = String(localized: "File ricontrollati.")
    }

    func revealInFinder(_ game: Game) {
        let files = game.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? game.nativeApp.map { [$0] } ?? [] : files)
    }

    /// Files dropped on the window.
    func importDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.importItems(urls) }
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Aggiungi")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in self.importItems(panel.urls) }
        }
    }

    // MARK: Switch

    /// One library entry per Switch game: base, updates and DLC together, with the engine profile's title and title ID.
    func organizeSwitchGames() {
        var changed = false
        var pending = Set(UserDefaults.standard.stringArray(forKey: "pendingSwitchFiles") ?? [])
        let pendingBefore = pending
        func role(_ url: URL) -> SwitchTitle.Role { switchInfo(url).role ?? .base }

        // 1. Each entry's title ID: from a file (name or container), else from the engine's profile.
        for var game in store.games where game.kind == .switchNative {
            let before = game
            let infos = game.files.map(switchInfo)
            let fromFiles = infos.first { $0.role == .base }?.baseID ?? infos.compactMap(\.baseID).first
            let profile = self.switchGames.profile(for: game)
            if let id = fromFiles ?? profile?.titleID {
                game.titleID = id
                if var ignored = UserDefaults.standard.stringArray(forKey: "ignoredNativeApps"), ignored.contains(id) {
                    ignored.removeAll { $0 == id }
                    UserDefaults.standard.set(ignored, forKey: "ignoredNativeApps")
                }
            }
            if let profile, game.nativeApp == nil, game.summary == nil, infos.contains(where: { ($0.role ?? .base) == .base }) { game.title = profile.name }
            if game != before { store.update(game); changed = true }
        }

        // 2. Files waiting for their base game: they join it as soon as it is in the library.
        for path in pending {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { pending.remove(path); continue }
            if var host = switchHost(for: url) {
                if !host.files.contains(url) { host.files.append(url); store.update(host); changed = true }
                pending.remove(path)
            }
        }

        // 3. Entries holding only an update or a DLC: into their game when it is there, else set aside (never two tiles for one game).
        for game in store.games where game.kind == .switchNative && game.nativeApp == nil {
            guard !game.files.isEmpty, game.files.allSatisfy({ role($0) != .base }) else { continue }
            if var host = switchHost(for: game.files[0], excluding: game.id) {
                host.files += game.files.filter { !host.files.contains($0) }
                store.update(host)
            } else {
                game.files.forEach { pending.insert($0.path) }
            }
            store.remove(ids: [game.id])
            changed = true
        }

        // 4. Two entries of the same game: one, keeping the one with the base game or the app.
        let groups = Dictionary(grouping: store.games.filter { $0.kind == .switchNative && $0.titleID != nil }, by: { $0.titleID! })
        for (_, group) in groups where group.count > 1 {
            let keeper = group.first { $0.nativeApp != nil } ?? group.first { $0.files.contains { role($0) == .base } } ?? group[0]
            var merged = keeper
            for other in group where other.id != keeper.id {
                merged.files += other.files.filter { !merged.files.contains($0) }
                merged.playTime += other.playTime
                merged.isFavorite = merged.isFavorite || other.isFavorite
                store.remove(ids: [other.id])
            }
            store.update(merged)
            changed = true
        }

        // Base first, then updates by version, then DLC.
        for var game in store.games where game.kind == .switchNative && game.files.count > 1 {
            var ranks: [URL: (Int, Int)] = [:]
            for url in game.files {
                let info = switchInfo(url)
                ranks[url] = ((info.role ?? .base) == .base ? 0 : info.role == .update ? 1 : 2, info.version ?? 0)
            }
            let sorted = game.files.sorted { ranks[$0]! < ranks[$1]! }
            if sorted != game.files { game.files = sorted; store.update(game); changed = true }
        }

        if pending != pendingBefore {
            UserDefaults.standard.set(Array(pending), forKey: "pendingSwitchFiles")
            let added = pending.subtracting(pendingBefore).count
            if added > 0 {
                message = String(localized: "\(added) aggiornamenti o DLC aspettano il loro gioco base.")
                ActivityLog.write("Set aside \(added) Switch updates or DLC without their base game")
            }
        }
        if changed { persist() }
        applyEngineStatus()
        fetchSwitchMetadata()
    }

    /// Updates and DLC waiting for their base game.
    var pendingSwitchFiles: [URL] {
        (UserDefaults.standard.stringArray(forKey: "pendingSwitchFiles") ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// The library entry a Switch file belongs to: same base title ID, or, for files without one, the same title.
    private func switchHost(for url: URL, excluding: UUID? = nil) -> Game? {
        let info = switchInfo(url)
        let candidates = store.games.filter { $0.kind == .switchNative && $0.id != excluding }
        if let base = info.baseID { return candidates.first { $0.titleID == base } }
        let wanted = SwitchFileInfo.baseTitle(url.lastPathComponent)
        guard !wanted.isEmpty else { return nil }
        return candidates.first { SwitchTitle.normalized($0.title) == wanted || SwitchTitle.normalized(cleanTitle(fromFileName: $0.files.first?.lastPathComponent ?? "")) == wanted }
    }

    /// A build needs the base game (or a Switch 2 NUP, which holds it): an update alone is not enough.
    func switchHasBase(_ game: Game) -> Bool {
        game.files.contains { $0.pathExtension.lowercased() == "nup" || (switchInfo($0).role ?? .base) == .base }
    }

    /// The versions the user has of a Switch game: the base (0) and each update's.
    func switchVersions(of game: Game) -> [Int] {
        Array(Set(game.files.compactMap { url -> Int? in
            let info = switchInfo(url)
            return (info.role ?? .base) == .dlc ? nil : (info.version ?? ((info.role ?? .base) == .base ? 0 : nil))
        })).sorted()
    }

    /// The version a build of this game packs: the user's choice, else the profile's recommendation among the user's versions.
    func switchBuildVersion(of game: Game) -> Int? {
        let available = switchVersions(of: game)
        if let chosen = game.buildVersion, available.contains(chosen) { return chosen }
        guard let id = game.titleID else { return available.max() }
        return switchGames.versions(for: id).choose(from: available)
    }

    /// The app is older than what the game now has: an update or DLC added, another version chosen, or a newer engine.
    func switchNeedsRebuild(_ game: Game) -> Bool {
        guard game.kind == .switchNative, game.nativeApp != nil, game.foundOnMac != true, let built = game.builtFiles else { return false }
        if Set(built) != Set(game.files.map(\.path)) { return true }
        if let version = switchBuildVersion(of: game), let builtVersion = game.builtVersion, version != builtVersion { return true }
        if let engine = switchGames.engine, let builtEngine = game.builtEngine, builtEngine != engine.commit { return true }
        return false
    }

    func setSwitchBuildVersion(_ version: Int?, for gameID: UUID) {
        guard var game = store.games.first(where: { $0.id == gameID }) else { return }
        game.buildVersion = version
        store.update(game)
        persist()
    }

    /// File identity, read once per file (the container's header may sit on a network drive).
    private func switchInfo(_ url: URL) -> SwitchFileInfo {
        if let cached = switchInfoCache[url] { return cached }
        let info = SwitchFileInfo.identify(url, readPackage: FileManager.default.fileExists(atPath: url.path))
        switchInfoCache[url] = info
        return info
    }

    /// nxnative apps already on the Mac (built by another front end or by hand) join the library, ready to play.
    func adoptNativeApps() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let apps = NXApp.scan(Array(Set([home.appendingPathComponent("Applications"), GamesLocation.macAppsFolder, NXPaths.appsFolder])))
        var changed = false
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredNativeApps") ?? [])
        for app in apps {
            if var game = store.games.first(where: { $0.kind == .switchNative && $0.titleID == app.titleID }) {
                let current = game.nativeApp.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                guard !current else { continue }
                game.nativeApp = app.url
                game.engineID = "nxnative"
                game.foundOnMac = !GamesLocation.isRetrotecaApp(app.url)
                store.update(game)
            } else {
                // Taken out of the library by the user: it comes back only when its game is added again.
                if ignored.contains(app.titleID) { continue }
                var game = Game(title: app.name, platformID: app.titleID.hasPrefix("04") ? "switch2" : "switch", kind: .switchNative,
                                files: [], status: .ready, engineID: "nxnative")
                game.nativeApp = app.url
                game.titleID = app.titleID
                game.foundOnMac = true
                store.add([game])
            }
            changed = true
            ActivityLog.write("Found the Mac app of \(app.name) (\(app.titleID)): \(app.url.path)")
        }
        if changed { persist(); applyEngineStatus() }
    }

    /// Banner, square image, title, description, publisher, year and genres from Nintendo's store, by title ID.
    /// - Parameter force: ask again even if the store was asked in the last 30 days.
    func fetchSwitchMetadata(force: Bool = false) {
        guard UserDefaults.standard.object(forKey: "downloadArtwork") as? Bool ?? true else { return }
        // Titles and descriptions come in the app's language: asked again when the language changes.
        let appLanguage = Locale.current.language.languageCode?.identifier ?? ""
        let force = force || UserDefaults.standard.string(forKey: "metadataLanguage") != appLanguage
        UserDefaults.standard.set(appLanguage, forKey: "metadataLanguage")
        let due = store.games.filter { game in
            game.kind == .switchNative && game.titleID != nil &&
            (force || game.screenshots == nil || game.metadataCheckedAt.map { Date().timeIntervalSince($0) > 30 * 86400 } ?? true)
        }
        guard !due.isEmpty else { return }
        let folder = libraryLocation.appendingPathComponent("Artwork", isDirectory: true)
        let language = Locale.current.language.languageCode?.identifier
        Task {
            for game in due {
                guard let titleID = game.titleID else { continue }
                let meta = (try? await SwitchMetadata.fetch(titleID: titleID, language: language)) ?? nil
                var updated = self.store.games.first { $0.id == game.id } ?? game
                updated.metadataCheckedAt = Date()
                if let meta {
                    if let title = meta.title, !title.isEmpty { updated.title = title }
                    updated.summary = meta.summary ?? updated.summary
                    updated.publisher = meta.publisher ?? updated.publisher
                    if !meta.genres.isEmpty { updated.genres = meta.genres }
                    updated.year = meta.year ?? updated.year
                    let base = "\(game.id.uuidString)-switch"
                    if let banner = meta.banner, await SwitchMetadata.download(banner, to: folder.appendingPathComponent("\(base)-banner.jpg")) {
                        updated.backdropURL = folder.appendingPathComponent("\(base)-banner.jpg")
                    }
                    if let square = meta.square, await SwitchMetadata.download(square, to: folder.appendingPathComponent("\(base)-square.jpg")) {
                        updated.coverURL = folder.appendingPathComponent("\(base)-square.jpg")
                    }
                    if let page = meta.page {
                        updated.screenshots = await Self.downloadScreenshots(from: page, into: folder, base: base)
                    }
                    for url in [updated.backdropURL, updated.coverURL].compactMap({ $0 }) + (updated.screenshots ?? []) { ArtworkCache.forget(url) }
                    ActivityLog.write("Nintendo store: \(updated.title) (\(titleID))")
                }
                if updated.screenshots == nil { updated.screenshots = [] }
                self.store.update(updated)
                self.persist()
            }
        }
    }

    /// The official screenshots of a Switch game, saved next to its banner ("<base>-shot-01.jpg"…); copies
    /// left from a longer list are removed.
    private static func downloadScreenshots(from page: URL, into folder: URL, base: String) async -> [URL] {
        var saved: [URL] = []
        for (index, url) in await SwitchMetadata.fetchScreenshots(page: page).enumerated() {
            let target = folder.appendingPathComponent(String(format: "%@-shot-%02d.jpg", base, index + 1))
            if await SwitchMetadata.download(url, to: target) { saved.append(target) }
        }
        let names = Set(saved.map(\.lastPathComponent))
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("\(base)-shot-") && !names.contains(old.lastPathComponent) {
            try? FileManager.default.removeItem(at: old)
        }
        return saved
    }

    // MARK: Builds

    struct BuildInfo {
        var state: NXBuildState
        var building: Bool
        var started: Date?
        var error: String?
        var engine: String?
        var log: URL?
        var canRetry: Bool
    }

    func buildInfo(for game: Game) -> BuildInfo {
        return BuildInfo(state: switchGames.builds[game.id] ?? NXBuildState(), building: switchGames.buildingID == game.id,
                         started: switchGames.buildStarted[game.id], error: switchGames.buildErrors[game.id],
                         engine: switchGames.engine.map { "\($0.name) \($0.shortCommit)" }, log: switchGames.logURL(for: game),
                         canRetry: !switchGames.isBusy && (switchGames.toolchain?.isReady ?? false))
    }

    func cancelBuild(of game: Game) {
        switchGames.cancel()
    }

    func retryBuild(_ game: Game) {
        buildSwitchGame(game)
    }

    /// The build running now.
    var buildingGameID: UUID? { switchGames.buildingID }

    func buildSwitchGame(_ game: Game) {
        switchGames.build(game, package: switchBuildVersion(of: game))
        if switchGames.buildingID == game.id { open(.build(game.id)) }
    }

    private func recordBuild(_ id: UUID, app: URL, state: NXBuildState) {
        guard var game = store.games.first(where: { $0.id == id }) else { return }
        // Built where new apps go now: the copy Retroteca made elsewhere before (on the Mac, another disk) goes.
        if let old = game.nativeApp, old.standardizedFileURL != app.standardizedFileURL, GamesLocation.isRetrotecaApp(old) {
            try? FileManager.default.removeItem(at: old)
            ActivityLog.write("Removed the previous app of \(game.title): \(old.path)")
        }
        game.nativeApp = app
        game.engineID = switchGames.engine?.id
        game.foundOnMac = false
        game.builtFiles = game.files.map(\.path)
        game.builtVersion = switchGames.lastPackage[id]
        game.builtEngine = switchGames.engine?.commit
        if let name = state.gameName, !name.isEmpty, game.summary == nil { game.title = name }
        if game.coverURL == nil, let icon = state.icon.map({ URL(fileURLWithPath: $0) }), FileManager.default.fileExists(atPath: icon.path) {
            let folder = libraryLocation.appendingPathComponent("Artwork", isDirectory: true)
            let destination = folder.appendingPathComponent("\(game.id.uuidString)-icon.jpg")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: icon, to: destination)) != nil {
                game.coverURL = destination
                ArtworkCache.forget(destination)
            }
        }
        store.update(game)
        applyEngineStatus()
        message = String(localized: "\(game.title) è pronto: ora è un'app Mac.")
        BuildNotifier.post(title: String(localized: "\(game.title) è pronto"), body: String(localized: "L'app Mac è costruita: aprila da Retroteca."))
    }

    // MARK: Games on an external disk

    /// Apps being moved to the chosen disk: done, total, the game being copied.
    @Published private(set) var moving: (done: Int, total: Int, title: String)?
    private var moveProcess: Process?
    private var moveCancelled = false

    /// Apps Retroteca built on this Mac, while games go to a disk.
    var appsOnMac: [Game] {
        guard GamesLocation.volume != nil else { return [] }
        return games.filter { game in
            game.nativeApp.map { $0.path.hasPrefix(GamesLocation.macAppsFolder.path + "/") && FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    /// Picks where games are built and kept; nil = this Mac. Not while a build or a move runs.
    func chooseGamesVolume(_ volume: URL?) {
        guard buildingGameID == nil, moving == nil else { return }
        GamesLocation.choose(volume)
        ActivityLog.write("Games now built and kept on \(volume?.path ?? "this Mac")")
        objectWillChange.send()
        space.measure(games: games)
    }

    /// Copies each app Retroteca built on the Mac to the chosen disk, checks the copy, then deletes the original.
    /// Stopping leaves every game whole, on one side or the other. Saves never move.
    func moveAppsToDisk() {
        guard moving == nil, buildingGameID == nil, runningGameID == nil, GamesLocation.volume != nil, GamesLocation.isAvailable else { return }
        let list = appsOnMac
        guard !list.isEmpty else { return }
        let destination = NXPaths.appsFolder
        moveCancelled = false
        moving = (0, list.count, list[0].title)
        Task {
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var moved = 0
            for (index, game) in list.enumerated() {
                guard !moveCancelled, let source = game.nativeApp else { break }
                moving = (index, list.count, game.title)
                let target = destination.appendingPathComponent(source.lastPathComponent)
                let ok = await copyApp(source, to: target)
                guard ok, !moveCancelled else {
                    try? FileManager.default.removeItem(at: target)
                    if !moveCancelled { message = String(localized: "\(game.title) non si è copiato: resta sul Mac.") }
                    ActivityLog.write("Move of \(game.title) to \(destination.path) \(moveCancelled ? "stopped" : "failed"); the app stays on the Mac")
                    break
                }
                try? FileManager.default.removeItem(at: source)
                if var current = store.games.first(where: { $0.id == game.id }) {
                    current.nativeApp = target
                    store.update(current)
                }
                persist()
                moved += 1
                ActivityLog.write("Moved \(game.title) to \(target.path)")
            }
            moving = nil
            moveProcess = nil
            if moved > 0 { message = moved == 1 ? String(localized: "1 gioco spostato.") : String(localized: "\(moved) giochi spostati.") }
            space.measure(games: games)
        }
    }

    func stopMoving() {
        moveCancelled = true
        moveProcess?.terminate()
    }

    /// `ditto` keeps the app's signature and attributes; the copy counts only when it holds the same files and bytes.
    private func copyApp(_ source: URL, to target: URL) async -> Bool {
        try? FileManager.default.removeItem(at: target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, target.path]
        moveProcess = process
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        guard status == 0 else { return false }
        return await Task.detached { FolderSummary.of(source) == FolderSummary.of(target) }.value
    }

    private func persist() {
        games = store.games
        do {
            try store.save()
        } catch {
            log.error("Library not saved: \(error.localizedDescription, privacy: .public)")
            message = String(localized: "La libreria non si salva: \(error.localizedDescription)")
        }
    }
}

extension Page {
    var isDetail: Bool {
        switch self {
        case .game, .build, .options, .space: return true
        default: return false
        }
    }
}
