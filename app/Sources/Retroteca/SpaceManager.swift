import Foundation
import RetrotecaCore

/// The user's choices about disk space (Settings → Spazio).
enum SpaceSettings {
    /// "compact": a build's caches are deleted once its app is ready; "fast": they stay for quick rebuilds.
    static let modeKey = "spaceMode"
    /// Gigabytes a build must leave free.
    static let keepFreeKey = "keepFreeGB"
    static let keepFreeChoices = [10, 20, 40, 80]

    static var compact: Bool { (UserDefaults.standard.string(forKey: modeKey) ?? "compact") == "compact" }
    static var keepFree: Int64 {
        let gb = UserDefaults.standard.object(forKey: keepFreeKey) as? Int ?? 20
        return Int64(gb) << 30
    }
}

/// What Retroteca takes on disk, measured the APFS way (clones counted once), and freeing a game's build caches.
@MainActor
final class SpaceManager: ObservableObject {
    struct Entry: Identifiable, Equatable {
        /// The title ID: one build folder per game.
        let id: String
        /// The build folder (on the Mac or on the chosen disk).
        var folder: URL
        var title: String
        var gameID: UUID?
        var space: GameSpace
    }

    struct Report: Equatable {
        var entries: [Entry]
        /// Engine checkout, its Python environment, covers, caches.
        var other: SpaceSize
        var freeDisk: Int64
        var capacity: Int64
        /// Disks attached now, for "Dove vanno i giochi".
        var volumes: [GamesVolume]

        var apps: Int64 { entries.reduce(0) { $0 + $1.space.app.allocated } }
        var shaders: Int64 { entries.reduce(0) { $0 + $1.space.shaders.own } }
        var otherCaches: Int64 { entries.reduce(0) { $0 + $1.space.otherCaches.own } }
        var leftovers: Int64 { entries.reduce(0) { $0 + $1.space.leftovers.own } }
        var total: Int64 { apps + shaders + otherCaches + leftovers + other.allocated }
        /// What Finder would add up: every copy counted.
        var finderTotal: Int64 {
            entries.reduce(other.allocated) { sum, entry in
                let s = entry.space
                return sum + s.app.allocated + s.shaders.allocated + s.otherCaches.allocated + s.leftovers.allocated
            }
        }
        var freeable: Int64 { entries.reduce(0) { $0 + $1.space.freeable } }
    }

    @Published private(set) var report: Report?
    @Published private(set) var isMeasuring = false
    /// Title IDs being freed.
    @Published private(set) var freeing: Set<String> = []
    private let paths = NXPaths.standard
    private let root: URL

    init(root: URL) { self.root = root }

    /// One game's entry in the last report.
    func entry(titleID: String?) -> Entry? {
        guard let titleID else { return nil }
        return report?.entries.first { $0.id == titleID }
    }

    /// Measures every Switch game Retroteca built or has a build folder for, off the main thread.
    func measure(games: [Game]) {
        guard !isMeasuring else { return }
        isMeasuring = true
        let paths = self.paths, root = self.root
        let known = games.filter { $0.kind == .switchNative && $0.titleID != nil }
        Task {
            let report = await Task.detached { Self.measure(known: known, paths: paths, root: root) }.value
            self.report = report
            self.isMeasuring = false
        }
    }

    nonisolated private static func measure(known: [Game], paths: NXPaths, root: URL) -> Report {
        let fm = FileManager.default
        // One folder per title ID, on the Mac or on the chosen disk; nothing else there (Finder's .DS_Store) is a game.
        var folders: [String: URL] = [:]
        for root in paths.workRoots {
            for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && SwitchTitle.titleID(inFileName: folder.lastPathComponent) == folder.lastPathComponent.uppercased() {
                folders[folder.lastPathComponent] = folder
            }
        }
        var ids = Set(folders.keys)
        for game in known where game.nativeApp != nil { ids.insert(game.titleID!) }
        var entries: [Entry] = []
        for id in ids {
            let game = known.first { $0.titleID == id }
            // Only apps Retroteca built: one another front end made stays its own.
            let app = game?.nativeApp.flatMap { GamesLocation.isRetrotecaApp($0) && fm.fileExists(atPath: $0.path) ? $0 : nil }
            let folder = folders[id] ?? paths.work(id)
            let space = BuildFolder.measure(folder, app: app)
            // A game out of the library with nothing left to free is not worth a row.
            if game == nil && space.freeable == 0 { continue }
            entries.append(Entry(id: id, folder: folder, title: game?.title ?? id, gameID: game?.id, space: space))
        }
        entries.sort { $0.space.total > $1.space.total }
        let otherFolders = [paths.engine, paths.venv, root.appendingPathComponent("Artwork"), root.appendingPathComponent("Cache")]
        let other = otherFolders.reduce(SpaceSize.zero) { $0 + DiskSpace.measure($1) }
        return Report(entries: entries, other: other, freeDisk: DiskSpace.free(), capacity: DiskSpace.capacity(),
                      volumes: GamesVolume.mounted())
    }

    /// Deletes a game's build caches (never while it builds); the app, saves and the user's files stay.
    func freeCaches(titleID: String, title: String, games: [Game], shaders: Bool = true, others: Bool = true) {
        guard !freeing.contains(titleID) else { return }
        freeing.insert(titleID)
        let folder = entry(titleID: titleID)?.folder ?? paths.work(titleID)
        Task {
            let freed = await Task.detached { BuildFolder.freeCaches(folder, shaders: shaders, others: others) }.value
            ActivityLog.write("Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of \(title)'s build caches")
            self.freeing.remove(titleID)
            self.measure(games: games)
        }
    }
}
